//
//  RenderScreen.swift
//  LiminalGenerator
//
//  Pinned API contract (see SPEC.md "Pinned API contract"): presented by
//  MainView in a `.fullScreenCover`. Matches
//  img/stitch_liminal_space_generator/share_clip/screen.png: giant
//  "ENCODING ANALOG SIGNAL" readout with a blinking block cursor, SRC/DEST
//  row, an outlined progress bar with a "REC \ ///"-style spinner that
//  fills CRT-green with overall progress, and a terminal log that grows as
//  render phases complete. On success, automatically presents the iOS
//  share sheet; after it's dismissed, offers DONE / RE-SHARE. Errors show
//  as glitch-magenta terminal lines with a RETRY option.
//

import SwiftUI
import UIKit

// MARK: - View model

@MainActor
final class RenderViewModel: ObservableObject {
    struct LogLine: Identifiable, Equatable {
        let id: String
        var text: String
    }

    enum Stage: Equatable {
        case encoding
        case complete(URL)
        case failed(String)
    }

    @Published private(set) var stage: Stage = .encoding
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var logLines: [LogLine] = []
    @Published var showShareSheet = false
    /// A frame captured at half the clip's duration, pre-generated off the
    /// main thread once the render completes and cached for reuse across
    /// DONE/RE-SHARE presentations, since `LPLinkMetadata`'s callback is
    /// synchronous and can't itself await an `AVAssetImageGenerator` call.
    @Published private(set) var shareThumbnail: UIImage?

    private let engine: AudioEngineController
    private let imageName: String
    private let timestamp: VHSTimestamp
    private var renderTask: Task<Void, Never>?
    private var lineIndex: [String: Int] = [:]

    init(engine: AudioEngineController, imageName: String, timestamp: VHSTimestamp) {
        self.engine = engine
        self.imageName = imageName
        self.timestamp = timestamp
    }

    func start() {
        renderTask?.cancel()
        logLines = []
        lineIndex = [:]
        overallProgress = 0
        showShareSheet = false
        stage = .encoding

        engine.pause() // Pause live playback while we render; renderOffline
                        // uses an entirely separate engine/DSP instance so
                        // this is purely a UX choice, not a technical need.

        renderTask = Task { [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        renderTask?.cancel()
    }

    /// Honors `LG_RENDER_SECONDS` (set by the UI test target's
    /// launchEnvironment) to render a short clip instead of the full 120s,
    /// so automated end-to-end tests don't have to wait a minute-plus for
    /// the encoder. Ordinary launches never set this env var, so normal
    /// behavior (120s, 3s fade in, 5s fade out) is unaffected.
    private func renderConfig() -> ClipRenderer.Config {
        guard let secondsString = ProcessInfo.processInfo.environment["LG_RENDER_SECONDS"],
              let seconds = Double(secondsString), seconds > 0 else {
            return ClipRenderer.Config()
        }
        return ClipRenderer.Config(duration: seconds,
                                    fadeIn: min(3, seconds * 0.25),
                                    fadeOut: min(5, seconds * 0.4))
    }

    private func run() async {
        do {
            let url = try await ClipRenderer.render(engine: engine, imageName: imageName, timestamp: timestamp, config: renderConfig()) { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }
            guard !Task.isCancelled else { return }
            setLine(key: "captured", text: "> SIGNAL CAPTURED [OK]")
            overallProgress = 1
            stage = .complete(url)

            // Pre-generate the share-sheet preview thumbnail (a mid-clip
            // frame, since the clip fades up from black) off the main
            // thread before presenting -- LPLinkMetadata's imageProvider
            // callback is synchronous, so it must already be cached by the
            // time the share sheet asks for it.
            shareThumbnail = await ShareThumbnailGenerator.generate(for: url)
            guard !Task.isCancelled else { return }
            showShareSheet = true
        } catch is CancellationError {
            // User cancelled; RenderScreen dismisses itself and this task's
            // cleanup (partial file removal) already happened inside
            // ClipRenderer.
        } catch {
            setLine(key: "error", text: "> ERROR: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            stage = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func apply(_ event: RenderProgress) {
        guard case .encoding = stage else { return }
        switch event.phase {
        case .tracking:
            setLine(key: "tracking", text: "> TRACKING... [OK]")
            overallProgress = max(overallProgress, 0.02)
        case .syncPulse:
            setLine(key: "sync", text: "> SYNC PULSE... [LOCKED]")
            overallProgress = max(overallProgress, 0.05)
        case .buffering(let fraction):
            let pct = Int((fraction * 100).rounded())
            setLine(key: "buffer", text: "> BUFFER... \(pct)%")
            overallProgress = max(overallProgress, 0.05 + fraction * 0.35)
        case .audioComplete:
            setLine(key: "buffer", text: "> BUFFER... 100%")
            setLine(key: "audio", text: "> AUDIO PASS... [OK]")
            overallProgress = max(overallProgress, 0.40)
        case .video(let fraction):
            let pct = Int((fraction * 100).rounded())
            setLine(key: "video", text: "> VIDEO PASS... \(pct)%")
            overallProgress = max(overallProgress, 0.40 + fraction * 0.53)
        case .muxing:
            setLine(key: "video", text: "> VIDEO PASS... 100%")
            setLine(key: "mux", text: "> MUX... [OK]")
            overallProgress = max(overallProgress, 0.97)
        }
    }

    private func setLine(key: String, text: String) {
        if let idx = lineIndex[key] {
            logLines[idx].text = text
        } else {
            lineIndex[key] = logLines.count
            logLines.append(LogLine(id: key, text: text))
        }
    }
}

// MARK: - RenderScreen

struct RenderScreen: View {
    @StateObject private var viewModel: RenderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var cursorOn = true
    @State private var spinnerIndex = 0
    private let spinnerFrames = ["\\", "|", "/", "-"]
    private let cursorTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let spinnerTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    init(engine: AudioEngineController, imageName: String, timestamp: VHSTimestamp) {
        _viewModel = StateObject(wrappedValue: RenderViewModel(engine: engine, imageName: imageName, timestamp: timestamp))
    }

    var body: some View {
        ZStack {
            Color.liminalBackground.ignoresSafeArea()

            VStack {
                Spacer(minLength: 0)
                content
                    .padding(.horizontal, LiminalMetrics.marginMobile)
                Spacer(minLength: 0)
            }

            ScanlineOverlay()
        }
        .preferredColorScheme(.dark)
        .onReceive(cursorTimer) { _ in cursorOn.toggle() }
        .onReceive(spinnerTimer) { _ in spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count }
        .onAppear { viewModel.start() }
        .sheet(isPresented: $viewModel.showShareSheet) {
            if case .complete(let url) = viewModel.stage {
                ShareSheet(items: [VideoShareItem(url: url, thumbnail: viewModel.shareThumbnail)])
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.stage {
        case .encoding:
            encodingView
        case .complete(let url):
            completeView(url: url)
        case .failed(let message):
            failedView(message: message)
        }
    }

    // MARK: Encoding state

    private var encodingView: some View {
        VStack(alignment: .leading, spacing: LiminalMetrics.stackLarge) {
            VStack(spacing: LiminalMetrics.stackMedium) {
                headerText
                progressBar
                logList(color: .liminalCRTGreenDim)
            }

            Button {
                viewModel.cancel()
                dismiss()
            } label: {
                Text("CANCEL")
            }
            .buttonStyle(DeckButtonStyle(tint: .liminalOnSurfaceVariant, background: .clear,
                                          borderColor: .liminalOutlineVariant, bottomBorderColor: .liminalOutlineVariant))
        }
    }

    private var headerText: some View {
        VStack(spacing: LiminalMetrics.stackSmall) {
            (Text("ENCODING ANALOG SIGNAL") + Text(cursorOn ? " \u{25AE}" : "  "))
                .font(.spaceMono(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundColor(.liminalPrimary)
                .shadow(color: .liminalCRTGreenDim.opacity(0.65), radius: 6)
                .shadow(color: .liminalGlitchMagenta.opacity(0.20), radius: 2, x: 1, y: 0)
                .accessibilityIdentifier("encodingHeaderText")

            srcDestRow
        }
    }

    private var srcDestRow: some View {
        HStack {
            Text("SRC: VTR_01")
            Spacer()
            Text("DEST: MEMORY")
        }
        .font(.spaceMono(size: 11))
        .tracking(1)
        .foregroundColor(.liminalOnSurfaceVariant)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.liminalSurfaceContainerLow
                Rectangle()
                    .fill(Color.liminalCRTGreenDim.opacity(0.85))
                    .frame(width: max(0, geo.size.width * CGFloat(viewModel.overallProgress)))
                    .animation(.linear(duration: 0.15), value: viewModel.overallProgress)
                Text("REC \(spinnerFrames[spinnerIndex]) ///")
                    .font(.spaceMono(size: 12, weight: .bold))
                    .tracking(2)
                    .foregroundColor(.white)
                    .blendMode(.difference)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(height: 34)
        .overlay(Rectangle().stroke(Color.liminalOutlineVariant, lineWidth: 1))
        .clipped()
    }

    private func logList(color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.logLines) { line in
                Text(line.text)
                    .foregroundColor(line.id == "error" ? .liminalGlitchMagenta : color)
            }
        }
        .font(.spaceMono(size: 12))
        .tracking(0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Complete state

    private func completeView(url: URL) -> some View {
        VStack(spacing: LiminalMetrics.stackLarge) {
            HStack {
                Text("STATUS: RENDER COMPLETE")
                    .foregroundColor(.liminalCRTGreenDim)
                Spacer()
                Text(url.lastPathComponent.uppercased())
                    .foregroundColor(.liminalOnSurfaceVariant)
            }
            .font(.spaceMono(size: 11))
            .tracking(1)
            .padding(.bottom, LiminalMetrics.stackSmall)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.liminalOutlineVariant).frame(height: 1)
            }

            logList(color: .liminalCRTGreenDim)

            VStack(spacing: LiminalMetrics.stackMedium) {
                Button {
                    viewModel.showShareSheet = true
                } label: {
                    Text("RE-SHARE")
                }
                .buttonStyle(DeckButtonStyle())

                Button {
                    dismiss()
                } label: {
                    Text("DONE")
                }
                .buttonStyle(DeckButtonStyle(tint: .liminalOnSurfaceVariant, background: .clear,
                                              borderColor: .liminalOutlineVariant, bottomBorderColor: .liminalOutlineVariant))
                .accessibilityIdentifier("doneButton")
            }
        }
    }

    // MARK: Failed state

    private func failedView(message: String) -> some View {
        VStack(spacing: LiminalMetrics.stackLarge) {
            Text("SIGNAL LOST")
                .font(.spaceMono(size: 26, weight: .bold))
                .foregroundColor(.liminalGlitchMagenta)
                .shadow(color: .liminalGlitchMagenta.opacity(0.7), radius: 6)

            logList(color: .liminalGlitchMagenta)

            Text(message)
                .font(.spaceMono(size: 11))
                .foregroundColor(.liminalGlitchMagenta)
                .multilineTextAlignment(.center)

            VStack(spacing: LiminalMetrics.stackMedium) {
                Button {
                    viewModel.start()
                } label: {
                    Text("RETRY")
                }
                .buttonStyle(DeckButtonStyle(tint: .liminalGlitchMagenta, borderColor: .liminalGlitchMagenta))

                Button {
                    dismiss()
                } label: {
                    Text("CANCEL")
                }
                .buttonStyle(DeckButtonStyle(tint: .liminalOnSurfaceVariant, background: .clear,
                                              borderColor: .liminalOutlineVariant, bottomBorderColor: .liminalOutlineVariant))
            }
        }
    }
}
