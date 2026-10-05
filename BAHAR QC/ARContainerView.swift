//
//  ARContainerView.swift
//  BAHAR QC
//
//  SwiftUI wrapper around a RealityKit ARView configured for horizontal-plane
//  detection. Detects the ground and hands it, plus the flood depth, to
//  FloodController, which renders the water (surface, underwater view and
//  waterline) as a full-screen post-process (FloodWater.metal).
//
//  Reports back to SwiftUI:
//    • `onGroundFound` — fires once when the ground estimate exists
//
//  iOS only.
//

#if os(iOS)

import ARKit
import AVFoundation
import RealityKit
import SwiftUI
import UIKit

struct ARContainerView: UIViewRepresentable {
    var floodDepth: Double
    var onGroundFound: (() -> Void)?
    var onSessionError: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onGroundFound: onGroundFound,
                    onSessionError: onSessionError)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session.delegate = context.coordinator
        context.coordinator.arView = view
        context.coordinator.flood = FloodController(arView: view, floodOnStart: false)

        guard ARWorldTrackingConfiguration.isSupported else {
            onSessionError?("ARKit world tracking is not supported on this device.")
            return view
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .denied, .restricted:
            onSessionError?("Camera access is denied. Go to Settings → BAHAR QC and enable Camera.")
            return view
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        context.coordinator.startSession()
                    } else {
                        context.coordinator.onSessionError?("Camera access was denied.")
                    }
                }
            }
            return view
        case .authorized:
            context.coordinator.startSession()
        @unknown default:
            context.coordinator.startSession()
        }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateDepth(floodDepth)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        var flood: FloodController?
        private var groundY: Float?
        private var groundIsEstimate: Bool = false
        private var horizontalPlanes: [UUID: ARPlaneAnchor] = [:]
        private let onGroundFound: (() -> Void)?
        let onSessionError: ((String) -> Void)?

        private var raycastTick: Int = 0
        // Lowest camera Y observed during this AR session. Used as a robust
        // floor estimate when ARKit fails to detect the real floor plane —
        // the camera-min minus a small offset is reliably at-or-near floor
        // level no matter how the user is holding the phone.
        private var lowestCameraY: Float?

        // 1.5 m² minimum — excludes chair seats (~0.16 m²) and most desk
        // surfaces (~0.9 m²), keeps real room floors.
        private let minFloorArea: Float = 1.5
        private let reanchorEpsilon: Float = 0.05
        private let estimatedFloorOffset: Float = 1.4

        init(onGroundFound: (() -> Void)?,
             onSessionError: ((String) -> Void)?) {
            self.onGroundFound = onGroundFound
            self.onSessionError = onSessionError
        }

        func startSession() {
            guard let arView else { return }
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            config.environmentTexturing = .automatic

            // No person segmentation — the water post-process shades over the
            // person, showing them through the refracted surface up to the
            // waterline (like the real flood effect in the reference peg).
            // Person segmentation caused the opposite effect: it cut the person
            // out of the water instead of showing them submerged inside it.
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }

        // MARK: ARSessionDelegate (errors)

        func session(_ session: ARSession, didFailWithError error: Error) {
            onSessionError?(error.localizedDescription)
        }

        func sessionWasInterrupted(_ session: ARSession) {
            onSessionError?("AR session was interrupted (camera in use or backgrounded).")
        }

        func updateDepth(_ depth: Double) {
            guard let flood else { return }
            // Mirror the MMDA noise floor (8 inches = 0.2032 m): drain the
            // water when the gauge reads "LITTLE TO NONE" so the AR matches
            // the HUD. Above it, the level rises to the full flood depth.
            if depth > 0.2032 {
                flood.setDepth(Float(depth))
            } else {
                flood.drain()
            }
        }

        // MARK: ARSessionDelegate (per-frame)

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Pre-plane camera-height fallback so water shows up fast.
            if groundY == nil, case .normal = frame.camera.trackingState {
                let cameraY = frame.camera.transform.columns.3.y
                install(at: cameraY - estimatedFloorOffset)
                groundIsEstimate = true
            }

            // Track lowest camera Y ever observed — this is our most reliable
            // floor reference. As the user moves the phone around, the
            // minimum approaches floor level (phone held low / near floor).
            if case .normal = frame.camera.trackingState {
                let cameraY = frame.camera.transform.columns.3.y
                let newLowest: Float
                if let prev = lowestCameraY {
                    newLowest = min(prev, cameraY)
                } else {
                    newLowest = cameraY
                }
                lowestCameraY = newLowest
                // Estimated floor = lowest camera position seen, minus a tiny
                // gap (phones aren't usually held *at* the floor).
                let cameraEstFloor = newLowest - 0.05
                // If the current ground anchor is HIGHER than this estimate,
                // pull it down. This guarantees the water can never sit above
                // the lowest spot the phone has been.
                if let current = groundY, current > cameraEstFloor {
                    groundY = cameraEstFloor
                    flood?.setFloor(cameraEstFloor)
                    groundIsEstimate = true
                }
            }

            // While the ground is still a camera-height guess, refine it with
            // ARKit raycasts. Estimated-plane raycasts return a real measured
            // surface height (fast, works before full plane anchors form) —
            // far more accurate than the fixed 1.4 m hand-height assumption,
            // which put the water surface ~15 cm too high whenever the phone
            // was held above 1.4 m.
            //
            // Rays are cast from several points down the lower half of the
            // screen, not just the centre — when the user frames a person
            // full-body, the centre lands on the person but the bottom of the
            // frame still sees ground. Adopting the LOWEST hit also guards
            // against locking onto benches / tables / raised surfaces.
            raycastTick &+= 1
            if raycastTick % 10 == 0, groundIsEstimate, let view = arView {
                let w = view.bounds.width
                let h = view.bounds.height
                let probePoints = [
                    CGPoint(x: w * 0.5, y: h * 0.50),
                    CGPoint(x: w * 0.5, y: h * 0.70),
                    CGPoint(x: w * 0.5, y: h * 0.88),
                    CGPoint(x: w * 0.25, y: h * 0.80),
                    CGPoint(x: w * 0.75, y: h * 0.80),
                ]
                var lowestHitY: Float?
                for point in probePoints {
                    if let hit = view.raycast(from: point,
                                              allowing: .estimatedPlane,
                                              alignment: .horizontal).first {
                        let hitY = hit.worldTransform.columns.3.y
                        lowestHitY = min(lowestHitY ?? hitY, hitY)
                    }
                }
                if let hitY = lowestHitY,
                   let current = groundY,
                   abs(hitY - current) > reanchorEpsilon {
                    groundY = hitY
                    flood?.setFloor(hitY)
                }
            }
        }

        // MARK: ARSessionDelegate (plane tracking)

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            ingest(anchors); reevaluateGround()
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            ingest(anchors); reevaluateGround()
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            for a in anchors { horizontalPlanes.removeValue(forKey: a.identifier) }
            reevaluateGround()
        }

        private func ingest(_ anchors: [ARAnchor]) {
            for anchor in anchors {
                guard let plane = anchor as? ARPlaneAnchor,
                      plane.alignment == .horizontal else { continue }
                horizontalPlanes[plane.identifier] = plane
            }
        }

        private func area(of plane: ARPlaneAnchor) -> Float {
            plane.planeExtent.width * plane.planeExtent.height
        }

        private func reevaluateGround() {
            let candidates = horizontalPlanes.values.filter { area(of: $0) >= minFloorArea }
            guard let floor = candidates.min(by: {
                $0.transform.columns.3.y < $1.transform.columns.3.y
            }) else { return }

            let newY = floor.transform.columns.3.y

            if groundY == nil {
                install(at: newY)
                groundIsEstimate = false
            } else if groundIsEstimate {
                // Replacing the initial camera-height estimate with a real
                // plane — only adopt if it's lower-or-equal. Otherwise the
                // water would jump UP to e.g. a desk-height plane the moment
                // ARKit detects one.
                if let current = groundY, newY <= current + reanchorEpsilon {
                    groundY = newY
                    flood?.setFloor(newY)
                    groundIsEstimate = false
                }
            } else if let current = groundY, newY < current - reanchorEpsilon {
                groundY = newY
                flood?.setFloor(newY)
            }
        }

        private func install(at y: Float) {
            groundY = y
            flood?.setFloor(y)
            onGroundFound?()
        }
    }
}

#endif
