//
//  ContentView.swift
//  BAHAR QC
//
//  Landing screen + AR session host. Mirrors the prototype's flow:
//  1. Landing card explains the experience.
//  2. Start AR → presents an ARKit horizontal-plane scene with a water plane
//     that rises to the GPS-looked-up flood depth, with MMDA-themed HUD
//     showing depth category, dynamic guidelines, and live GPS.
//

import CoreLocation
import SwiftUI

struct ContentView: View {
    @State private var showingAR = false

    var body: some View {
        #if os(iOS)
        if showingAR {
            ARSessionView(onExit: { showingAR = false })
        } else {
            LandingView(onStart: { showingAR = true })
        }
        #else
        LandingView(onStart: {})
            .overlay(alignment: .bottom) {
                Text("AR features require iOS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        #endif
    }
}

// MARK: - MMDA theme tokens

private enum MMDATheme {
    // Hex-derived colours from the official MMDA gauge palette.
    static let patv  = Color(red: 234/255, green: 179/255, blue:   8/255) // #EAB308
    static let nplv  = Color(red: 249/255, green: 115/255, blue:  22/255) // #F97316
    static let npatv = Color(red: 239/255, green:  68/255, blue:  68/255) // #EF4444
    static let neutral = Color(red: 100/255, green: 116/255, blue: 139/255) // slate-500

    static func color(for category: MMDAGauge.Category) -> Color {
        switch category {
        case .none:  return neutral
        case .patv:  return patv
        case .nplv:  return nplv
        case .npatv: return npatv
        }
    }
}

/// A frosted-glass card style — slate-900 base, blur, hairline border.
private struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(red: 15/255, green: 23/255, blue: 42/255).opacity(0.78)) // slate-900/78
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

private extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

// MARK: - Landing

private struct LandingView: View {
    let onStart: () -> Void

    @ViewBuilder
    private var noahLogo: some View {
        #if os(iOS)
        if let uiImage = UIImage(named: "NOAH LOGO") {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
        #endif
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            noahLogo
                .frame(maxWidth: 220, maxHeight: 80)

            VStack(spacing: 6) {
                Text("BAHAR")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .tracking(2)
                Text("Baha Augmented Reality")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Metro Manila's First AR Flood App")
                    .font(.headline)
                Text("Powered by UP NOAH's 100-year flood return model. Point your camera at the ground to see the expected flood depth at your current location.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            Spacer()

            Button(action: onStart) {
                Text("Start AR")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            Text("Prototype — designed for outdoor, ground-level use. Geolocation accuracy may vary depending on GPS signal and device.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - AR session

#if os(iOS)
private struct ARSessionView: View {
    let onExit: () -> Void

    @StateObject private var location = LocationManager()
    @State private var flood = FloodData()
    @State private var floodReady = false
    @State private var loadError: String?
    @State private var depth: Double = 0
    @State private var gauge: MMDAGauge = .none
    @State private var groundFound = false
    @State private var arError: String?
    @State private var underwater: Bool = false

    var body: some View {
        ZStack {
            ARContainerView(
                floodDepth: depth,
                onGroundFound: { groundFound = true },
                onSessionError: { msg in arError = msg },
                onUnderwaterChange: { isUnder in underwater = isUnder }
            )
            .ignoresSafeArea()

            UnderwaterPOVOverlay(active: underwater)

            if let arError {
                VStack(spacing: 6) {
                    Text("AR session error").font(.caption.bold())
                    Text(arError).font(.caption).multilineTextAlignment(.center)
                    Text("Check Settings → BAHAR QC → Camera permission.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
                .glassCard(cornerRadius: 14)
                .foregroundStyle(.white)
                .padding()
            }

            // ===== HUD =====
            VStack(spacing: 10) {
                gpsCapsule
                    .padding(.top, 56)

                depthCard
                    .padding(.horizontal)

                Spacer()

                if !groundFound {
                    Text("Point camera at the ground to detect floor")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassCard(cornerRadius: 20)
                        .foregroundStyle(.white)
                }

                guidelinesCard
                    .padding(.horizontal)
                    .padding(.bottom, 24)
            }

            // Exit button overlaid in top-right.
            VStack {
                HStack {
                    Spacer()
                    Button(action: onExit) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                            Text("Exit")
                                .font(.subheadline.bold())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassCard(cornerRadius: 20)
                        .foregroundStyle(.white)
                    }
                }
                Spacer()
            }
            .padding()
        }
        .task {
            location.start()
            await loadFloodData()
        }
        .onChange(of: location.lastLocation) { newValue in
            guard let coord = newValue?.coordinate else { return }
            Task { await refreshDepth(latitude: coord.latitude, longitude: coord.longitude) }
        }
        .onDisappear { location.stop() }
    }

    // MARK: - HUD components

    /// Top-centre floating GPS pill. Glowing dot signals fix quality.
    private var gpsCapsule: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(gpsDotColor.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .blur(radius: 2)
                Circle()
                    .fill(gpsDotColor)
                    .frame(width: 8, height: 8)
            }
            Text(gpsText)
                .font(.system(.footnote, design: .monospaced).weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 20)
        .foregroundStyle(.white)
    }

    /// Main depth/category readout card. Active level is the largest element.
    private var depthCard: some View {
        VStack(spacing: 10) {
            if gauge.category == .none {
                Text("NO FLOOD AT THIS LOCATION")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(MMDATheme.color(for: .none))
            } else {
                Text(gauge.category.abbreviation)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(MMDATheme.color(for: gauge.category), in: Capsule())

                Text(activeLevelLabel)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)

                Text(depthDisplay)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text(gauge.category.fullName)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .glassCard()
    }

    /// Dynamic safety guidance — text changes with the active flood category.
    private var guidelinesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: guidelinesIcon)
                    .foregroundStyle(MMDATheme.color(for: gauge.category))
                Text("Guidelines & Emergency Hotlines")
                    .font(.footnote.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(.white)
            }
            Text(guidelinesText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard()
    }

    // MARK: - HUD bindings

    private var gpsText: String {
        if let err = loadError { return err }
        if !floodReady { return "Loading flood data…" }
        switch location.authorizationStatus {
        case .notDetermined: return "Requesting location…"
        case .denied, .restricted: return "Location denied"
        default: break
        }
        guard let loc = location.lastLocation else { return "Waiting for GPS…" }
        return String(format: "%.5f, %.5f  ±%.0fm",
                      loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy)
    }

    /// Signal-quality colour: green when accurate, yellow when slow, red when down.
    private var gpsDotColor: Color {
        if loadError != nil { return MMDATheme.npatv }
        if !floodReady { return MMDATheme.patv }
        switch location.authorizationStatus {
        case .denied, .restricted: return MMDATheme.npatv
        case .notDetermined: return MMDATheme.patv
        default: break
        }
        guard let loc = location.lastLocation else { return MMDATheme.patv }
        if loc.horizontalAccuracy > 50 { return MMDATheme.patv }
        return Color.green
    }

    /// MMDA-style level label e.g. "GUTTER LEVEL", "KNEE LEVEL".
    private var activeLevelLabel: String {
        let inches = depth * 39.3700787
        if inches < 10 { return "GUTTER LEVEL" }
        if inches < 13 { return "HALF-KNEE LEVEL" }
        if inches < 19 { return "HALF-TIRE LEVEL" }
        if inches < 26 { return "KNEE LEVEL" }
        if inches < 37 { return "TIRE LEVEL" }
        if inches < 45 { return "WAIST LEVEL" }
        return "CHEST LEVEL"
    }

    /// Depth in inches, rounded — matches the MMDA reference card markings.
    private var depthDisplay: String {
        let inches = Int(depth * 39.3700787 + 0.5)
        return "\(inches)\""
    }

    private var guidelinesIcon: String {
        switch gauge.category {
        case .none:  return "checkmark.shield.fill"
        case .patv:  return "exclamationmark.triangle.fill"
        case .nplv:  return "exclamationmark.octagon.fill"
        case .npatv: return "xmark.octagon.fill"
        }
    }

    private var guidelinesText: String {
        switch gauge.category {
        case .none:
            return "Safe — no flooding expected at this location for the 100-year return period."
        case .patv:
            return "Proceed slowly. Keep distance from trucks and large vehicles."
        case .nplv:
            return "Warning: light vehicles must detour immediately. Avoid wading."
        case .npatv:
            return "CRITICAL: do not attempt driving or wading. Seek higher ground."
        }
    }

    // MARK: - Data

    private func loadFloodData() async {
        do {
            try await flood.load()
            floodReady = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshDepth(latitude: Double, longitude: Double) async {
        let d = await flood.depth(latitude: latitude, longitude: longitude) ?? 0
        let g = await flood.gauge(for: d)
        await MainActor.run {
            depth = d
            gauge = g
        }
    }
}
#endif

#Preview {
    LandingView(onStart: {})
}
