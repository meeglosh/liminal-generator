import SwiftUI

@main
struct LiminalGeneratorApp: App {
    @State private var showSplash = true
    /// True once the splash has actually finished fading out (not merely
    /// started to), i.e. the real-world moment `VHSImageCard`'s first-launch
    /// PLAY typewriter reveal needs to key off of instead of guessing the
    /// same 2.0s hold + 0.4s fade duration a second time from its own,
    /// separately-timed mount. See `splashDismissed` in `VHSImageCard.swift`.
    @State private var splashFullyDismissed = false
    @StateObject private var tipStore = TipStore()

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainView()

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .environmentObject(tipStore)
            .environment(\.splashDismissed, splashFullyDismissed)
            .preferredColorScheme(.dark)
            .task {
                guard showSplash else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                withAnimation(.easeOut(duration: 0.4)) {
                    showSplash = false
                } completion: {
                    splashFullyDismissed = true
                }
            }
            #if DEBUG
            .task { await AutoRenderDebugHarness.runIfRequested() }
            #endif
        }
    }
}
