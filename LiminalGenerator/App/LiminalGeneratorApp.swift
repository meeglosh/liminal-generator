import SwiftUI

@main
struct LiminalGeneratorApp: App {
    @State private var showSplash = true
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
                }
            }
            #if DEBUG
            .task { await AutoRenderDebugHarness.runIfRequested() }
            #endif
        }
    }
}
