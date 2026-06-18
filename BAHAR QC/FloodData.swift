//
//  FloodData.swift
//  BAHAR QC
//
//  Mapbox Tilequery-backed flood depth lookup. Mirrors the JS version
//  (js/flood-data-ios.js): hits the Netlify-proxied tilequery endpoint for
//  the `upri-noah.mm_fh_100yr_tls` tileset and caches results on a ~55 m grid
//  so GPS pings don't hammer the API.
//
//  depth(latitude:longitude:) →
//    nil  = outside Metro Manila coverage
//    0    = inside coverage, no flood polygon at this point
//    >0   = flood depth in metres (the `Var` property from the tileset)
//

import Foundation

/// Classification of flood depth using the MMDA Flood Gauge System
/// (PATV / NPLV / NPATV) plus the descriptive sub-label motorists recognise.
nonisolated struct MMDAGauge: Equatable, Sendable {
    enum Category: String, Sendable {
        case none, patv, nplv, npatv

        var abbreviation: String {
            switch self {
            case .none: return ""
            case .patv: return "PATV"
            case .nplv: return "NPLV"
            case .npatv: return "NPATV"
            }
        }

        var fullName: String {
            switch self {
            case .none:  return "NO FLOOD IN THIS AREA"
            case .patv:  return "PASSABLE TO ALL TYPES OF VEHICLES"
            case .nplv:  return "NOT PASSABLE TO LIGHT VEHICLES"
            case .npatv: return "NOT PASSABLE TO ALL TYPES OF VEHICLES"
            }
        }
    }

    let category: Category
    let description: String

    static let none = MMDAGauge(category: .none, description: "")

    /// Maps a depth in metres to its MMDA gauge classification. Thresholds are
    /// the inch markers from the official system (8, 10, 13, 19, 26, 37, 45).
    ///
    /// `noiseFloor` = MMDA's official gutter-deep threshold of 8 inches
    /// (0.2032 m). Below 8" MMDA does not assign a vehicle-passability
    /// category, so neither do we — the card reads "LITTLE TO NONE",
    /// matching both NOAH Studio's "Little to None" wording and the MMDA
    /// gauge's lowest tier boundary. Above 8" the official gauge kicks in:
    /// 8-10" gutter, 10-13" half-knee, etc.
    static func from(depthMeters: Double) -> MMDAGauge {
        let noiseFloor = 0.2032 // 8 inches = MMDA's lowest classified depth
        guard depthMeters > noiseFloor else { return .none }
        let inches = depthMeters * 39.3700787

        if inches < 10  { return MMDAGauge(category: .patv,  description: "Gutter deep flood") }
        if inches < 13  { return MMDAGauge(category: .patv,  description: "Half-knee deep flood") }
        if inches < 19  { return MMDAGauge(category: .nplv,  description: "Half tire deep flood") }
        if inches < 26  { return MMDAGauge(category: .nplv,  description: "Knee deep flood") }
        if inches < 37  { return MMDAGauge(category: .npatv, description: "Tire deep flood") }
        if inches < 45  { return MMDAGauge(category: .npatv, description: "Waist deep flood") }
        return MMDAGauge(category: .npatv, description: "Chest deep flood")
    }
}

actor FloodData {
    /// Netlify-proxied tilequery endpoint. Same one the web client uses; the
    /// Mapbox token lives server-side in `netlify/functions/tilequery.js`.
    private static let endpoint = URL(string: "https://bahar-mm.netlify.app/api/tilequery")!

    /// Metro Manila bounding box — anything outside returns nil so the AR
    /// shows nothing rather than a meaningless 0.
    private enum Bounds {
        static let north = 14.82
        static let south = 14.35
        static let west  = 120.90
        static let east  = 121.20
    }

    /// In-memory cache keyed by quantized lat/lon (~55 m grid).
    private var cache: [String: Double] = [:]

    var isReady: Bool { true }

    /// No-op. Tilequery has nothing to preload — kept for API parity with the
    /// old bundled-binary loader so callers don't have to change.
    func load() async throws {}

    /// Returns flood depth in metres at the given WGS-84 coordinate.
    func depth(latitude lat: Double, longitude lon: Double) async -> Double? {
        guard lat >= Bounds.south, lat <= Bounds.north,
              lon >= Bounds.west,  lon <= Bounds.east else { return nil }

        let key = cacheKey(lat: lat, lon: lon)
        if let cached = cache[key] { return cached }

        var comps = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "lat", value: "\(lat)"),
            URLQueryItem(name: "lon", value: "\(lon)"),
        ]
        guard let url = comps.url else { return cache[key] ?? 0 }

        var request = URLRequest(url: url)
        // Short timeout — AR queries should fail fast, not hang the depth UI.
        request.timeoutInterval = 5.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // Don't cache failures — caller may retry on next GPS tick.
                return cache[key] ?? 0
            }
            let decoded = try JSONDecoder().decode(TilequeryResponse.self, from: data)
            // Max depth across overlapping polygons, matching the JS loader.
            var maxDepth: Double = 0
            for feature in decoded.features {
                if let v = feature.properties.varValue, v > maxDepth {
                    maxDepth = v
                }
            }
            cache[key] = maxDepth
            return maxDepth
        } catch {
            return cache[key] ?? 0
        }
    }

    func gauge(for depth: Double) -> MMDAGauge {
        MMDAGauge.from(depthMeters: depth)
    }

    /// Quantize to ~55 m (0.0005°) so multiple GPS pings near the same spot
    /// share one cached answer. Identical key shape to the JS cache.
    private func cacheKey(lat: Double, lon: Double) -> String {
        let qLat = Int((lat * 2000).rounded())
        let qLon = Int((lon * 2000).rounded())
        return "\(qLat),\(qLon)"
    }
}

// MARK: - Tilequery response decoding

nonisolated private struct TilequeryResponse: Decodable {
    let features: [Feature]

    nonisolated struct Feature: Decodable {
        let properties: Properties
    }

    nonisolated struct Properties: Decodable {
        /// The tileset stores depth-in-metres under the property name `Var`.
        /// Some tilesets emit it as a JSON number, others as a string —
        /// accept both rather than fail.
        let varValue: Double?

        private enum CodingKeys: String, CodingKey { case Var }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let d = try? c.decode(Double.self, forKey: .Var) {
                varValue = d
            } else if let s = try? c.decode(String.self, forKey: .Var),
                      let d = Double(s) {
                varValue = d
            } else {
                varValue = nil
            }
        }
    }
}
