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

/// True clear-glass card — bg-white/5 + heavy backdrop blur + white/10 border +
/// soft drop shadow. Lets the live AR feed and water visualization show
/// through clearly while keeping text legible.
private struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.30), radius: 16, x: 0, y: 8)
    }
}

private extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

// MARK: - Share sheet (UIActivityViewController wrapper)

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Captures the current key window — includes the live ARView Metal feed,
/// the SwiftUI glassmorphic HUD overlay, and the water shader output, all
/// flattened into a single UIImage.
private func captureKeyWindow() -> UIImage? {
    guard let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) else { return nil }
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    return renderer.image { _ in
        // `afterScreenUpdates: false` captures the current frame including
        // Metal-rendered content (ARKit camera feed + RealityKit water).
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
    }
}
#endif

// MARK: - Landing

private struct LandingView: View {
    let onStart: () -> Void

    @ViewBuilder
    private var partnerLogos: some View {
        #if os(iOS)
        HStack(spacing: 18) {
            if let noah = UIImage(named: "NOAH LOGO") {
                Image(uiImage: noah)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 36)
                    .shadow(color: .white.opacity(0.55), radius: 6, x: 0, y: 0)
                    .shadow(color: .white.opacity(0.40), radius: 12, x: 0, y: 0)
            }
            if let upri = UIImage(named: "UPRI LOGO") {
                Image(uiImage: upri)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 36)
            }
        }
        #endif
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            partnerLogos
                .frame(maxWidth: 280)
                .padding(.horizontal)

            VStack(spacing: 6) {
                // "BahAR" stylized: "Bah" lowercase, "AR" uppercase to
                // emphasize the Augmented Reality side of the brand.
                (Text("Bah")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                 + Text("AR")
                    .font(.system(size: 56, weight: .heavy, design: .rounded)))
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
        // Always render the landing page in light mode so the wordmark, logo
        // glow, and copy stay on white regardless of the user's device theme.
        .preferredColorScheme(.light)
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

    // Snapshot UI state
    @State private var flashOpacity: Double = 0
    @State private var snapshotImage: UIImage?
    @State private var showingShareSheet = false
    @State private var thumbnailVisible = false
    @State private var thumbnailDragOffset: CGSize = .zero

    // Guidelines / hotlines expansion state.
    @State private var showHotlines = false

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

            }

            // Top row: NOAH logo (left, translucent) + Exit (right).
            VStack {
                HStack(alignment: .top) {
                    noahLogoOverlay
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
                // Bottom row: warning button + thumbnail (left) | camera (right).
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        snapshotThumbnail
                        guidelinesCard
                    }
                    Spacer()
                    Button(action: takeSnapshot) {
                        Image(systemName: "camera.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .glassCard(cornerRadius: 28)
                    }
                    .accessibilityLabel("Take AR snapshot")
                }
            }
            .padding()

            // Flash overlay — fades out after each capture.
            Color.white
                .ignoresSafeArea()
                .opacity(flashOpacity)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showingShareSheet) {
            if let img = snapshotImage {
                ShareSheet(items: [img])
            }
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

    /// Translucent NOAH logo, top-left. Soft white glow keeps the black parts
    /// of the mark legible against dark backgrounds.
    @ViewBuilder
    private var noahLogoOverlay: some View {
        if let uiImage = UIImage(named: "NOAH LOGO") {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 90, maxHeight: 36)
                .opacity(0.85)
                // Multi-pass white glow — outer haze + inner halo. Lifts the
                // black strokes of the wordmark off dark camera backgrounds.
                .shadow(color: .white.opacity(0.55), radius: 6, x: 0, y: 0)
                .shadow(color: .white.opacity(0.40), radius: 12, x: 0, y: 0)
        }
    }

    /// iOS-screenshot-style thumbnail of the most recent snapshot. Slides in
    /// from the bottom-left after capture. Tap → opens share sheet (save
    /// already happened automatically). Swipe-left → dismiss the thumbnail
    /// like the real iOS screenshot preview. Also auto-dismisses after 5s.
    @ViewBuilder
    private var snapshotThumbnail: some View {
        if thumbnailVisible, let img = snapshotImage {
            Button {
                showingShareSheet = true
            } label: {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
                    .overlay(alignment: .bottomTrailing) {
                        // Larger share glyph so the call-to-action reads clearly.
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.black.opacity(0.65), in: Circle())
                            .overlay(
                                Circle().stroke(Color.white.opacity(0.30), lineWidth: 1)
                            )
                            .padding(4)
                    }
            }
            .offset(x: thumbnailDragOffset)
            .opacity(1.0 - min(Double(abs(thumbnailDragOffset)) / 120.0, 0.9))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Only allow swipe to the left (negative X). Resist right.
                        thumbnailDragOffset = min(value.translation.width, 0)
                    }
                    .onEnded { value in
                        if value.translation.width < -60 {
                            // Swiped far enough — dismiss.
                            withAnimation(.easeOut(duration: 0.25)) {
                                thumbnailDragOffset = -200
                                thumbnailVisible = false
                            }
                            // Reset for next snapshot.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                thumbnailDragOffset = 0
                            }
                        } else {
                            // Snap back.
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                thumbnailDragOffset = 0
                            }
                        }
                    }
            )
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

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

    /// Main depth/category readout. Compact layout with the human-scale
    /// label as the largest element, depth numeric next to it, and a tight
    /// secondary row underneath for the vehicle-classification pill.
    private var depthCard: some View {
        VStack(spacing: 4) {
            if gauge.category == .none {
                HStack(spacing: 6) {
                    Text("✅")
                        .font(.system(size: 24))
                    Text("NO FLOOD")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.white)
                }
                Text("Safe at this location")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.70))
            } else {
                // PRIMARY — human-scale label with body-part emoji.
                HStack(alignment: .center, spacing: 8) {
                    Text(humanScaleEmoji)
                        .font(.system(size: 30))
                    Text(humanScaleLabel)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                // Numeric accent — both imperial and metric, monospace.
                Text(depthDisplay)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                // SECONDARY — vehicle classification with category color pill.
                HStack(spacing: 6) {
                    Text(gauge.category.abbreviation)
                        .font(.system(.caption2, design: .rounded).weight(.heavy))
                        .tracking(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(MMDATheme.color(for: gauge.category), in: Capsule())
                    Text(gauge.category.fullName)
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.2)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.leading)
                }
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .glassCard(cornerRadius: 14)
    }

    /// Tiny warning badge — category-coloured icon in a glass circle, fixed
    /// 44×44 so the row stays symmetric with the 56-pt camera button on the
    /// right. Tap to reveal the advisory text as a popover anchored above
    /// the button, so the layout never reflows.
    @ViewBuilder
    private var guidelinesCard: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                showHotlines.toggle()
            }
        } label: {
            Image(systemName: guidelinesIcon)
                .font(.title2.weight(.bold))
                .foregroundStyle(MMDATheme.color(for: gauge.category))
                .frame(width: 56, height: 56)
                .glassCard(cornerRadius: 28)
        }
        .accessibilityLabel(showHotlines ? "Hide flood advisory" : "Show flood advisory")
        .overlay(alignment: .bottomLeading) {
            if showHotlines {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: guidelinesIcon)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(MMDATheme.color(for: gauge.category))
                        .frame(width: 24, height: 24)
                    Text(guidelinesText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 260, alignment: .leading)
                .glassCard()
                // Float the card above the button — leaves the bottom row
                // (warning + camera) symmetric and unchanged.
                .offset(y: -68)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
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

    /// Human-scale flood level label. Same thresholds as MMDA but worded for
    /// the human body to make the depth instantly relatable.
    private var humanScaleLabel: String {
        let inches = depth * 39.3700787
        if inches < 10 { return "GUTTER LEVEL" }
        if inches < 13 { return "HALF-KNEE LEVEL" }
        if inches < 19 { return "CALF LEVEL" }
        if inches < 26 { return "KNEE LEVEL" }
        if inches < 37 { return "THIGH LEVEL" }
        if inches < 45 { return "WAIST LEVEL" }
        return "CHEST LEVEL"
    }

    /// Body-part emoji that visually corresponds to the depth tier.
    private var humanScaleEmoji: String {
        let inches = depth * 39.3700787
        if inches < 10 { return "🥾" }
        if inches < 13 { return "🦵" }
        if inches < 19 { return "🦵" }
        if inches < 26 { return "🦵" }
        if inches < 37 { return "🚴" }
        if inches < 45 { return "🧍" }
        return "👤"
    }

    /// Depth in both imperial and metric: e.g. `8" / ~0.20 m`.
    private var depthDisplay: String {
        let inches = Int(depth * 39.3700787 + 0.5)
        return String(format: "%d\" / ~%.2f m", inches, depth)
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

    // MARK: - AR Snapshot

    /// Captures the live AR frame + HUD overlay, plays a camera-flash effect,
    /// saves directly to the Photos library, and slides in an iOS-screenshot-
    /// style thumbnail at the bottom-left. Tap the thumbnail to share further
    /// (AirDrop, Messages, etc.); it auto-dismisses after a few seconds.
    private func takeSnapshot() {
        // Capture FIRST so the flash overlay isn't included in the image.
        let image = captureKeyWindow()

        // Quick white flash for capture feedback.
        flashOpacity = 0.9
        withAnimation(.easeOut(duration: 0.35)) {
            flashOpacity = 0
        }

        // Tiny haptic to confirm.
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        guard let image else { return }

        // Save straight to Photos. Permission string lives in the target's
        // INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription.
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

        snapshotImage = image
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            thumbnailVisible = true
        }
        // Auto-dismiss after 5 seconds unless the user tapped to share.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            // Don't yank the thumbnail out from under an active share sheet.
            guard !showingShareSheet else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                thumbnailVisible = false
            }
        }
    }
}
#endif

#Preview {
    LandingView(onStart: {})
}
