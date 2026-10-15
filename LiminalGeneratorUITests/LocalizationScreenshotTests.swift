//
//  LocalizationScreenshotTests.swift
//  LiminalGeneratorUITests
//
//  Opt-in: skipped unless LG_SHOT_LANG is set (so the normal English suite is
//  unaffected). Launches the app in the given language and writes PNGs of the
//  splash, main screen (collapsed and with BASS/DRUMS expanded), About sheet,
//  render screen and render-complete screen to LG_SHOT_DIR.
//
//    TEST_RUNNER_LG_SHOT_LANG=de TEST_RUNNER_LG_SHOT_DIR=$PWD/docs/localization/de \
//      xcodebuild test -project LiminalGenerator.xcodeproj -scheme "Liminal Generator" \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
//      -only-testing:LiminalGeneratorUITests/LocalizationScreenshotTests
//
//  Language code -> locale: es es_ES, pt-BR pt_BR, fr fr_FR, de de_DE, ja ja_JP.
//

import XCTest

final class LocalizationScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private let locales = ["es": "es_ES", "pt-BR": "pt_BR", "fr": "fr_FR", "de": "de_DE", "ja": "ja_JP", "en": "en_US"]

    func testCaptureLocalizedScreens() throws {
        guard let lang = ProcessInfo.processInfo.environment["LG_SHOT_LANG"], !lang.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_LG_SHOT_LANG to capture localized screenshots.")
        }
        let dir = ProcessInfo.processInfo.environment["LG_SHOT_DIR"]
        func shot(_ app: XCUIApplication, _ name: String) {
            let png = app.screenshot()
            let att = XCTAttachment(screenshot: png)
            att.name = "\(lang)_\(name)"
            att.lifetime = .keepAlways
            add(att)
            if let dir {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? png.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }

        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(lang))", "-AppleLocale", locales[lang] ?? "en_US"]
        app.launchEnvironment = ["LG_RENDER_SECONDS": "4", "LG_RESET_LANGUAGE": "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "00_splash")

        XCTAssertTrue(app.staticTexts["mainHeaderTitle"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 4) // let the PLAY typewriter intro settle
        // Start playback so the image chip (location name) is visible.
        let play = app.buttons["playPauseButton"]
        if play.waitForExistence(timeout: 5) { play.tap() }
        Thread.sleep(forTimeInterval: 2.5)
        shot(app, "01_main_top")

        // Expand BASS and DRUMS so their rows are laid out too.
        scrollUntil(app) { app.buttons["bassToggle"].isHittable }
        app.buttons["bassToggle"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        shot(app, "02_main_bass")
        scrollUntil(app) { app.buttons["drumsToggle"].isHittable }
        app.buttons["drumsToggle"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        scrollBy(app, times: 2)
        shot(app, "03_main_drums")

        // About sheet.
        scrollBy(app, times: -10)
        app.buttons["aboutButton"].tap()
        Thread.sleep(forTimeInterval: 1.2)
        shot(app, "04_about_top")
        let sheet = app.scrollViews.firstMatch
        let picker = app.buttons["languagePicker"]
        var guardN = 0
        while !picker.isHittable && guardN < 8 { sheet.swipeUp(velocity: .slow); guardN += 1 }
        Thread.sleep(forTimeInterval: 0.5)
        shot(app, "05_about_language")
        picker.tap()
        Thread.sleep(forTimeInterval: 0.8)
        shot(app, "05b_language_menu")
        if app.buttons["日本語"].exists { app.buttons["日本語"].firstMatch.tap() } // dismiss menu...
        Thread.sleep(forTimeInterval: 0.8)
        shot(app, "05c_after_picking_ja")
        // ...then restore System Default (first option) so later shots use the launch language.
        picker.tap()
        Thread.sleep(forTimeInterval: 0.6)
        let sys = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'system' OR label CONTAINS[c] 'sistema' OR label CONTAINS[c] 'système' OR label CONTAINS[c] 'システム' OR label CONTAINS[c] 'padrão'")).firstMatch
        if sys.exists { sys.tap() }
        Thread.sleep(forTimeInterval: 0.8)
        sheet.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 0.5)
        shot(app, "05_about_credits")
        sheet.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 0.5)
        shot(app, "06_about_bottom")
        app.swipeDown()
        Thread.sleep(forTimeInterval: 0.8)

        // Render screen.
        let render = app.buttons["renderShareButton"]
        scrollUntil(app) { render.isHittable }
        shot(app, "07_main_bottom")
        render.tap()
        XCTAssertTrue(app.staticTexts["encodingHeaderText"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.0)
        shot(app, "08_render_encoding")

        let done = app.buttons["doneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 90))
        Thread.sleep(forTimeInterval: 3.5)
        for label in ["Close", "Cancel", "Done"] {
            let b = app.buttons[label]
            if b.waitForExistence(timeout: 1), b.isHittable { b.tap(); break }
        }
        if !app.buttons["shareTipButton"].isHittable { app.swipeDown() }
        Thread.sleep(forTimeInterval: 1)
        shot(app, "09_render_complete")

        let tip = app.buttons["shareTipButton"]
        if tip.waitForExistence(timeout: 5), tip.isHittable {
            tip.tap()
            Thread.sleep(forTimeInterval: 1.5)
            shot(app, "10_tip_jar")
        }
    }

    private func scrollBy(_ app: XCUIApplication, times: Int) {
        let target = app.scrollViews.firstMatch
        for _ in 0..<abs(times) {
            let a = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: times > 0 ? 0.85 : 0.15))
            let b = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: times > 0 ? 0.15 : 0.85))
            a.press(forDuration: 0.05, thenDragTo: b)
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func scrollUntil(_ app: XCUIApplication, _ cond: () -> Bool) {
        var n = 0
        while !cond() && n < 12 { scrollBy(app, times: 1); n += 1 }
    }
}
