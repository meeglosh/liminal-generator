//
//  AutoRenderDebugHarness.swift
//  LiminalGenerator
//
//  DEBUG-only smoke-test hook for the render pipeline, launched via env
//  var "LG_AUTORENDER"="1" (optionally "LG_RENDER_SECONDS"="8" to render a
//  short clip instead of the full 120s, and "LG_AUTORENDER_DRUMS"="1" to
//  enable drums before rendering -- audio verification hook, DEBUG-only).
//  Drives `ClipRenderer` end-to-end with no UI interaction and prints
//  progress/result to stdout so it can be captured via `xcrun simctl launch
//  --console-pty` / `simctl spawn ... log stream`.
//
//  This lives entirely in Render/ (no edits to MainView/App files owned by
//  other agents). Swift disallows overriding the Objective-C `+load`/
//  `+initialize` hooks directly, so the pre-main entry point instead comes
//  from a tiny C constructor (`AutoRenderBootstrap.c`, `__attribute__((
//  constructor))`, run by dyld before `main()`) that calls this file's
//  `@_cdecl`-exported `lg_autorender_bootstrap()`. It never fires unless
//  the env var is explicitly set, so ordinary launches are unaffected.
//

#if DEBUG
import Foundation

@_cdecl("lg_autorender_bootstrap")
func lg_autorender_bootstrap() {
    guard ProcessInfo.processInfo.environment["LG_AUTORENDER"] == "1" else { return }
    let seconds = ProcessInfo.processInfo.environment["LG_RENDER_SECONDS"].flatMap(Double.init) ?? 120
    Task { @MainActor in
        await AutoRenderDebugHarness.runAutoRender(seconds: seconds)
    }
}

enum AutoRenderDebugHarness {
    @MainActor
    static func runAutoRender(seconds: Double) async {
        print("[LG_AUTORENDER] starting harness duration=\(seconds)s")

        let engine = AudioEngineController()
        if ProcessInfo.processInfo.environment["LG_AUTORENDER_DRUMS"] == "1" {
            engine.drumsEnabled = true
            print("[LG_AUTORENDER] drums enabled via LG_AUTORENDER_DRUMS, loop=\(engine.currentBeat.displayName) bpm=\(engine.currentBeat.bpm)")
        }
        let imageName = ImageLibrary[Int.random(in: 0..<ImageLibrary.count)].assetName
        let timestamp = VHSTimestamp.random()
        let config = ClipRenderer.Config(duration: seconds,
                                          fadeIn: min(3, seconds * 0.25),
                                          fadeOut: min(5, seconds * 0.4))

        let start = Date()
        do {
            let url = try await ClipRenderer.render(engine: engine,
                                                      imageName: imageName,
                                                      timestamp: timestamp,
                                                      config: config) { event in
                print("[LG_AUTORENDER] phase=\(event.phase)")
            }
            let elapsed = Date().timeIntervalSince(start)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            print("[LG_AUTORENDER] SUCCESS path=\(url.path) sizeBytes=\(size) elapsedSeconds=\(elapsed)")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("[LG_AUTORENDER] FAILURE error=\(error) elapsedSeconds=\(elapsed)")
        }
    }
}
#endif
