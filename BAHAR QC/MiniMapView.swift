//
//  MiniMapView.swift
//  BAHAR QC
//
//  Mapbox-rendered NOAH map: the noah-frontend terrain basemap with the
//  Metro Manila 100-yr flood-depth tileset overlaid at runtime — the same
//  source + step-expression pattern the NOAH/MMDA web maps use, translated
//  to the Mapbox Maps iOS SDK. The public access token lives in
//  BAHAR-QC-Info.plist under MBXAccessToken.
//
//  Used twice by the AR HUD:
//    • mini mode — small non-interactive map pinned to the HUD, follows GPS
//    • expanded mode — large pannable/zoomable map shown when tapped
//

#if os(iOS)

import CoreLocation
@preconcurrency import MapboxMaps
import SwiftUI
import UIKit

struct NOAHMapView: UIViewRepresentable {
    var coordinate: CLLocationCoordinate2D?
    /// `false` = mini HUD map: gestures off, camera follows the GPS fix.
    /// `true`  = expanded map: pan/zoom enabled, centers once then hands
    /// control to the user.
    var interactive: Bool

    private static let styleURI = StyleURI(rawValue:
        "mapbox://styles/upri-noah/ckupb1t4ybxq517s530madpso")!

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hasCentered = false
        var cancelables = Set<AnyCancelable>()
    }

    func makeUIView(context: Context) -> MapView {
        let options = MapInitOptions(
            cameraOptions: CameraOptions(
                center: coordinate ?? CLLocationCoordinate2D(latitude: 14.6539, longitude: 121.0685),
                zoom: interactive ? 16 : 15
            ),
            styleURI: Self.styleURI
        )
        let mapView = MapView(frame: .zero, mapInitOptions: options)

        mapView.gestures.options.panEnabled = interactive
        mapView.gestures.options.pinchEnabled = interactive
        mapView.gestures.options.doubleTapToZoomInEnabled = interactive
        mapView.gestures.options.doubleTouchToZoomOutEnabled = interactive
        mapView.gestures.options.rotateEnabled = false
        mapView.gestures.options.pitchEnabled = false
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden

        // Blue location puck.
        mapView.location.options.puckType = .puck2D(.makeDefault(showBearing: false))

        mapView.mapboxMap.onStyleLoaded.observeNext { _ in
            Self.addFloodLayers(to: mapView.mapboxMap)
        }.store(in: &context.coordinator.cancelables)

        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        guard let coordinate else { return }
        if interactive {
            if !context.coordinator.hasCentered {
                context.coordinator.hasCentered = true
                mapView.mapboxMap.setCamera(to: CameraOptions(center: coordinate, zoom: 16))
            }
        } else {
            let camera = CameraOptions(center: coordinate, zoom: 15)
            if context.coordinator.hasCentered {
                mapView.camera.ease(to: camera, duration: 0.4)
            } else {
                mapView.mapboxMap.setCamera(to: camera)
                context.coordinator.hasCentered = true
            }
        }
    }

    /// Metro Manila 100-yr flood depth overlay — mirrors the MMDA web app:
    /// 9 source-layers, colored by the `Var` property (depth in meters).
    private static func addFloodLayers(to map: MapboxMap) {
        let sourceID = "mm-flood-depth"
        var source = VectorSource(id: sourceID)
        source.url = "mapbox://upri-noah.mm_fh_100yr_tls"

        // Depth ranges from Flow_Legend_v2 (same as mmda-app):
        //   0.20–0.50 m yellow · 0.51–1.00 m orange · 1.01–2.00 m magenta
        //   2.01–5.00 m purple · 5.01+ m cobalt
        let depthColor = Exp(.step) {
            Exp(.get) { "Var" }
            "rgba(0,0,0,0)"
            0.20
            "#FFFF00"
            0.51
            "#FF8C00"
            1.01
            "#FF00AA"
            2.01
            "#8B008B"
            5.01
            "#0047AB"
        }

        do {
            try map.addSource(source)
            // No 'i' in the tileset's source-layer suffixes.
            for suffix in ["a", "b", "c", "d", "e", "f", "g", "h", "j"] {
                var layer = FillLayer(id: "mm-flood-depth-\(suffix)", source: sourceID)
                layer.sourceLayer = "mm_fh_100yr_\(suffix)"
                layer.fillColor = .expression(depthColor)
                layer.fillOpacity = .constant(0.65)
                try map.addLayer(layer)
            }
        } catch {
            // Map stays usable as plain basemap if the overlay fails.
            print("Flood overlay failed: \(error)")
        }
    }
}

#endif
