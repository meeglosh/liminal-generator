//
//  LanguagePickerTests.swift
//  LiminalGeneratorUITests
//
//  Opens the About sheet, switches the in-app language to Español via the
//  dropdown, checks localized labels change live, then switches back.
//

import XCTest

final class LanguagePickerTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLanguagePickerSwitchesLiveAndBack() throws {
        let app = XCUIApplication()
        // LG_RESET_LANGUAGE clears any persisted choice at launch (DEBUG only).
        app.launchEnvironment = ["LG_RESET_LANGUAGE": "1"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        // Whatever happens, leave the persisted choice cleared for other tests.
        addTeardownBlock {
            let cleanup = XCUIApplication()
            cleanup.launchEnvironment = ["LG_RESET_LANGUAGE": "1"]
            cleanup.launch()
            cleanup.terminate()
        }

        let about = app.buttons["aboutButton"]
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        about.tap()
        XCTAssertTrue(app.navigationBars["ABOUT"].waitForExistence(timeout: 5), "About sheet should open in English")

        let picker = app.buttons["languagePicker"]
        scrollUntilHittable(picker, in: app)
        XCTAssertTrue(picker.isHittable, "Language picker should be reachable in the About sheet")

        // English -> Español
        picker.tap()
        let spanish = app.buttons["Español"]
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "Menu should list Español in its own language")
        spanish.tap()
        XCTAssertTrue(app.navigationBars["ACERCA DE"].waitForExistence(timeout: 5),
                      "Navigation title should switch live to Spanish")

        // Español -> English (option names stay in their own language).
        scrollUntilHittable(picker, in: app)
        picker.tap()
        let english = app.buttons["English"]
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.tap()
        XCTAssertTrue(app.navigationBars["ABOUT"].waitForExistence(timeout: 5),
                      "Navigation title should switch back to English")
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 10) {
        var n = 0
        while !element.isHittable && n < maxSwipes {
            let sv = app.scrollViews.firstMatch
            let a = sv.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let b = sv.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            a.press(forDuration: 0.05, thenDragTo: b)
            n += 1
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}
