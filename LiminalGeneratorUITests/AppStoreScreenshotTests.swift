//
//  AppStoreScreenshotTests.swift
//  Opt-in (skipped unless LG_SHOT_LANG is set). Captures the five App Store
//  states (main/playing, bass, drums, export, CRT intro) to LG_SHOT_DIR.
//
import XCTest

final class AppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private let locales = ["es": "es_ES", "pt-BR": "pt_BR", "fr": "fr_FR", "de": "de_DE", "ja": "ja_JP", "en": "en_US"]

    func testCaptureAppStoreStates() throws {
        guard let lang = ProcessInfo.processInfo.environment["LG_SHOT_LANG"], !lang.isEmpty,
              let dir = ProcessInfo.processInfo.environment["LG_SHOT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_LG_SHOT_LANG and TEST_RUNNER_LG_SHOT_DIR.")
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ app: XCUIApplication, _ name: String) {
            let png = app.screenshot()
            try? png.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(lang))", "-AppleLocale", locales[lang] ?? "en_US"]
        app.launchEnvironment = ["LG_RENDER_SECONDS": "4", "LG_RESET_LANGUAGE": "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["mainHeaderTitle"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 5) // PLAY intro settles
        shot(app, "05-crt-intro")

        app.buttons["playPauseButton"].tap()
        Thread.sleep(forTimeInterval: 3)
        shot(app, "01-main")

        let scroll = app.scrollViews.firstMatch
        func drag(_ pts: CGFloat) {
            let a = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.0)).withOffset(CGVector(dx: 0, dy: 650))
            let b = a.withOffset(CGVector(dx: 0, dy: -pts))
            a.press(forDuration: 0.1, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.6)
            Thread.sleep(forTimeInterval: 0.5)
        }
        var n = 0
        while !app.buttons["bassToggle"].isHittable && n < 8 { drag(150); n += 1 }
        app.buttons["bassToggle"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        drag(510)
        shot(app, "02-bass")

        n = 0
        while !app.buttons["drumsToggle"].isHittable && n < 10 { drag(250); n += 1 }
        app.buttons["drumsToggle"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        for _ in 0..<4 { drag(400) }
        shot(app, "03-drums")

        let render = app.buttons["renderShareButton"]
        n = 0
        while !render.isHittable && n < 6 { drag(250); n += 1 }
        render.tap()
        XCTAssertTrue(app.buttons["doneButton"].waitForExistence(timeout: 90))
        Thread.sleep(forTimeInterval: 3.5)
        for label in ["Close", "Cancel", "Done"] {
            let b = app.buttons[label]
            if b.waitForExistence(timeout: 1), b.isHittable { b.tap(); break }
        }
        if !app.buttons["shareTipButton"].isHittable { app.swipeDown() }
        Thread.sleep(forTimeInterval: 1)
        shot(app, "04-export")
    }
}
