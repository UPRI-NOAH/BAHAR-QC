//
//  ARContainerView.swift
//  BAHAR QC
//
//  SwiftUI wrapper around a RealityKit ARView configured for horizontal-plane
//  detection. Renders a 3D water plane via CustomMaterial (WaterShader.metal)
//  with live screen-space reflection sampled from the camera feed.
//
//  Reports two signals back to SwiftUI:
//    • `onGroundFound` — fires once when the ground anchor exists
//    • `onUnderwaterChange` — fires whenever the camera crosses above/below
//       the waterline, so the parent view can overlay an underwater POV
//
//  iOS only.
//

#if os(iOS)

import ARKit
import AVFoundation
import Metal
import RealityKit
import SwiftUI
import UIKit

struct ARContainerView: UIViewRepresentable {
    var floodDepth: Double
    var onGroundFound: (() -> Void)?
    var onSessionError: ((String) -> Void)?
    /// Fires when the camera moves above/below the water plane.
    /// `true` = camera Y is below the water surface (submerged POV).
    var onUnderwaterChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onGroundFound: onGroundFound,
                    onSessionError: onSessionError,
                    onUnderwaterChange: onUnderwaterChange)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session.delegate = context.coordinator
        context.coordinator.arView = view

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
        private var waterAnchor: AnchorEntity?
        private var waterEntity: ModelEntity?
        private var groundY: Float?
        private var groundIsEstimate: Bool = false
        private var currentDepth: Double = 0
        private var horizontalPlanes: [UUID: ARPlaneAnchor] = [:]
        private let cameraPipeline: CameraReflectionPipeline?
        private let onGroundFound: (() -> Void)?
        let onSessionError: ((String) -> Void)?
        private let onUnderwaterChange: ((Bool) -> Void)?

        private var lastUnderwater: Bool = false
        private var cameraFrameTick: Int = 0

        private let minFloorArea: Float = 0.15
        private let reanchorEpsilon: Float = 0.05
        private let estimatedFloorOffset: Float = 1.4

        init(onGroundFound: (() -> Void)?,
             onSessionError: ((String) -> Void)?,
             onUnderwaterChange: ((Bool) -> Void)?) {
            self.onGroundFound = onGroundFound
            self.onSessionError = onSessionError
            self.onUnderwaterChange = onUnderwaterChange
            self.cameraPipeline = CameraReflectionPipeline()
        }

        func startSession() {
            guard let arView else { return }
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]

            // No person segmentation — we want the water to render OVER the
            // person, so they appear submerged through the translucent water
            // rather than being masked out in front of it.
            config.environmentTexturing = .automatic

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
            currentDepth = depth
            applyDepth()
        }

        private func applyDepth() {
            guard let entity = waterEntity else { return }
            let height = max(Float(currentDepth), 0.001)
            entity.transform.translation = [0, height, 0]
        }

        // MARK: ARSessionDelegate (per-frame)

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Pre-plane camera-height fallback so water shows up fast.
            if groundY == nil, case .normal = frame.camera.trackingState {
                let cameraY = frame.camera.transform.columns.3.y
                install(at: cameraY - estimatedFloorOffset)
                groundIsEstimate = true
            }

            // Underwater detection. Compare camera world Y to water surface Y.
            if let groundY {
                let waterY = groundY + Float(currentDepth)
                let camY = frame.camera.transform.columns.3.y
                let nowUnderwater = (currentDepth > 0) && (camY < waterY)
                if nowUnderwater != lastUnderwater {
                    lastUnderwater = nowUnderwater
                    onUnderwaterChange?(nowUnderwater)
                }
            }

            // Camera reflection pipeline: capture frame metadata on this (main)
            // thread, dispatch the YpCbCr → RGB Metal compute to the pipeline's
            // background queue. Throttled to every other frame.
            cameraFrameTick &+= 1
            if cameraFrameTick % 2 == 0,
               let pipeline = cameraPipeline,
               let view = arView {
                let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
                if let job = CameraReflectionPipeline.makeJob(
                    frame: frame,
                    viewportSize: view.bounds.size,
                    orientation: orientation
                ) {
                    pipeline.processingQueue.async {
                        pipeline.process(job)
                    }
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
                groundY = newY
                waterAnchor?.transform.translation = [0, newY, 0]
                groundIsEstimate = false
            } else if let current = groundY, newY < current - reanchorEpsilon {
                groundY = newY
                waterAnchor?.transform.translation = [0, newY, 0]
            }
        }

        private func install(at y: Float) {
            guard let arView else { return }
            groundY = y

            let anchor = AnchorEntity(world: [0, y, 0])
            // Subdivided mesh so the vertex-displacement geometry modifier
            // (waterGeometry in WaterShader.metal) has vertices to push up
            // and down — a single quad would only displace at four corners.
            let mesh = Self.makeSubdividedPlane(size: 30, subdivisions: 80)

            let entity = ModelEntity(mesh: mesh, materials: [makeWaterMaterial()])
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)

            self.waterAnchor = anchor
            self.waterEntity = entity
            applyDepth()
            self.onGroundFound?()
        }

        private func makeWaterMaterial() -> any RealityKit.Material {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let library = device.makeDefaultLibrary() else {
                return fallbackWaterMaterial()
            }
            let surfaceShader = CustomMaterial.SurfaceShader(named: "waterSurface", in: library)
            let geometryModifier = CustomMaterial.GeometryModifier(named: "waterGeometry", in: library)
            do {
                var material = try CustomMaterial(
                    surfaceShader: surfaceShader,
                    geometryModifier: geometryModifier,
                    lightingModel: .lit
                )
                material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
                if let resource = cameraPipeline?.textureResource {
                    material.custom.texture = .init(resource)
                }
                return material
            } catch {
                onSessionError?("Water shader failed to load: \(error.localizedDescription)")
                return fallbackWaterMaterial()
            }
        }

        /// Procedurally-built subdivided plane mesh. The default
        /// `MeshResource.generatePlane` returns a single quad (4 vertices), so
        /// per-vertex wave displacement only moves the corners. This builds a
        /// proper grid of triangles so the geometry-modifier shader can shape
        /// real waves across the surface.
        private static func makeSubdividedPlane(size: Float, subdivisions: Int) -> MeshResource {
            let count = subdivisions + 1
            let half  = size * 0.5
            var positions: [SIMD3<Float>] = []
            var normals:   [SIMD3<Float>] = []
            var uvs:       [SIMD2<Float>] = []
            positions.reserveCapacity(count * count)
            normals.reserveCapacity(count * count)
            uvs.reserveCapacity(count * count)
            for j in 0..<count {
                for i in 0..<count {
                    let u = Float(i) / Float(subdivisions)
                    let v = Float(j) / Float(subdivisions)
                    positions.append(SIMD3<Float>(u * size - half, 0, v * size - half))
                    normals.append(SIMD3<Float>(0, 1, 0))
                    uvs.append(SIMD2<Float>(u, v))
                }
            }
            var indices: [UInt32] = []
            indices.reserveCapacity(subdivisions * subdivisions * 6)
            for j in 0..<subdivisions {
                for i in 0..<subdivisions {
                    let tl = UInt32(j * count + i)
                    let tr = tl + 1
                    let bl = tl + UInt32(count)
                    let br = bl + 1
                    indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
                }
            }
            var descriptor = MeshDescriptor(name: "subdividedWaterPlane")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.normals   = MeshBuffers.Normals(normals)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
            descriptor.primitives = .triangles(indices)
            // The mesh is simple and known-valid; force-try keeps the call site clean.
            return try! MeshResource.generate(from: [descriptor])
        }

        private func fallbackWaterMaterial() -> any RealityKit.Material {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: UIColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1.0))
            material.blending = .transparent(opacity: .init(floatLiteral: 0.6))
            material.roughness = 0.05
            material.metallic = 0.6
            return material
        }
    }
}

#endif
