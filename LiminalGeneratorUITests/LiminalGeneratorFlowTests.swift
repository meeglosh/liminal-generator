//
//  LiminalGeneratorFlowTests.swift
//  LiminalGeneratorUITests
//
//  One end-to-end flow test driving the whole app: splash -> play/pause ->
//  regenerate melody -> adjust GLOBAL ENV sliders -> enable LOFI BEATS &
//  generate a beat (LOOP readout changes) -> render & share -> dismiss. Launches with
//  LG_RENDER_SECONDS=8 so `RenderScreen` renders a short clip instead of the
//  full 120s (see RenderScreen.swift's `renderConfig()`), keeping the test
//  fast without touching render logic quality.
//
//  Every screenshot is attached to the test result AND written directly to
//  the scratchpad `uitest/` directory (the simulator process shares the
//  host filesystem, so a plain FileManager write from the test process is
//  visible to the host immediately).
//

import XCTest

final class LiminalGeneratorFlowTests: XCTestCase {

    private let screenshotDir = URL(fileURLWithPath:
        "/private/tmp/claude-501/-Users-mikejerugim-liminal-generator/760bb4a1-4c05-451e-b850-31664aa8f0ff/scratchpad/uitest"
    )

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
    }

    func testFullGeneratorFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["LG_RENDER_SECONDS": "8"]
        app.launch()

        // MARK: 1. Splash -> main header

        let header = app.staticTexts["mainHeaderTitle"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "Main header should appear after splash")

        let playPauseButton = app.buttons["playPauseButton"]
        XCTAssertTrue(waitHittable(playPauseButton, timeout: 10), "Play/pause control should become hittable once splash clears")

        saveScreenshot(app, name: "01_main_top.png")

        // MARK: 2. Idle PLAY state -> tap -> PAUSE

        XCTAssertTrue(playPauseButton.label.uppercased().contains("PLAY"),
                      "App should start paused, showing PLAY (autoplay-on-launch was removed). Label was: \(playPauseButton.label)")
        XCTAssertFalse(playPauseButton.label.uppercased().contains("PAUSE"),
                       "Idle label should not already say PAUSE. Label was: \(playPauseButton.label)")

        playPauseButton.tap()

        let flippedToPause = waitFor(timeout: 5) {
            playPauseButton.label.uppercased().contains("PAUSE")
        }
        XCTAssertTrue(flippedToPause, "Play control should flip to PAUSE after tapping PLAY. Label was: \(playPauseButton.label)")

        saveScreenshot(app, name: "02_after_play.png")

        // MARK: 3. Generate melody -> PROG/BPM readout changes

        let seqReadout = app.staticTexts["seqReadout"]
        let bpmReadout = app.staticTexts["bpmReadout"]
        XCTAssertTrue(seqReadout.waitForExistence(timeout: 5))
        XCTAssertTrue(bpmReadout.waitForExistence(timeout: 5))

        let generateMelodyButton = app.buttons["generateMelodyButton"]
        XCTAssertTrue(generateMelodyButton.exists)

        let initialSeq = seqReadout.label
        let initialBpm = bpmReadout.label

        var changed = false
        for _ in 0..<3 {
            generateMelodyButton.tap()
            // give SwiftUI a beat to publish the new pattern
            _ = waitFor(timeout: 1.5) { false }
            if seqReadout.label != initialSeq || bpmReadout.label != initialBpm {
                changed = true
                break
            }
        }
        XCTAssertTrue(changed, "PROG or BPM readout should change after tapping GENERATE MELODY at least once in 3 tries. prog=\(seqReadout.label) bpm=\(bpmReadout.label)")

        // MARK: 3b. COLOR slider exists in the SYNTH card (below PROG/BPM) & is adjustable

        let colorSlider = app.otherElements["colorSlider"]
        scrollUntilHittable(colorSlider, in: app)
        XCTAssertTrue(colorSlider.exists, "COLOR slider should exist in the SYNTH card")
        XCTAssertTrue(colorSlider.isHittable, "COLOR slider should be scrolled into view")
        dragSlider(colorSlider)

        // MARK: 3c. Waveform chips (SINE/TRIANGLE/SQUARE/SAW) exist below COLOR,
        // default selection is SINE (ambient-pad pivot changed the engine's
        // default waveform), and tapping a different chip flips the
        // accessibility-selected state (LiminalSelectableChip reports
        // .isSelected via the .isSelected accessibility trait).

        let sineChip = app.buttons["waveformChip_sine"]
        let triangleChip = app.buttons["waveformChip_triangle"]
        let squareChip = app.buttons["waveformChip_square"]
        let sawChip = app.buttons["waveformChip_saw"]

        scrollUntilHittable(sineChip, in: app)
        XCTAssertTrue(sineChip.exists, "SINE waveform chip should exist")
        XCTAssertTrue(triangleChip.exists, "TRIANGLE waveform chip should exist")
        XCTAssertTrue(squareChip.exists, "SQUARE waveform chip should exist")
        XCTAssertTrue(sawChip.exists, "SAW waveform chip should exist")
        XCTAssertTrue(sineChip.isSelected, "SINE should be selected by default (engine.waveform default is .sine)")

        XCTAssertTrue(squareChip.isHittable, "SQUARE chip should be scrolled into view")
        squareChip.tap()

        let selectionFlipped = waitFor(timeout: 2) {
            squareChip.isSelected && !sineChip.isSelected
        }
        XCTAssertTrue(selectionFlipped, "Tapping SQUARE should select it and deselect SINE")

        // MARK: 3d. BASSLINE card (between SYNTH and GLOBAL ENV): enable ->
        // COLOR/LEVEL sliders + GENERATE BASS appear -> adjust -> generate.

        let bassToggle = app.buttons["bassToggle"]
        scrollUntilHittable(bassToggle, in: app)
        XCTAssertTrue(bassToggle.exists, "BASS toggle should exist")
        bassToggle.tap()

        let bassColorSlider = app.otherElements["bassColorSlider"]
        XCTAssertTrue(bassColorSlider.waitForExistence(timeout: 3), "BASSLINE COLOR slider should appear once BASS is enabled")

        let bassLevelSlider = app.otherElements["bassLevelSlider"]
        XCTAssertTrue(bassLevelSlider.waitForExistence(timeout: 3), "BASSLINE LEVEL slider should appear once BASS is enabled")

        let generateBassButton = app.buttons["generateBassButton"]
        XCTAssertTrue(generateBassButton.waitForExistence(timeout: 3), "GENERATE BASS should appear once BASS is enabled")

        scrollUntilHittable(bassColorSlider, in: app)
        XCTAssertTrue(bassColorSlider.isHittable, "BASSLINE COLOR slider should be scrolled into view")
        dragSlider(bassColorSlider)

        scrollUntilHittable(bassLevelSlider, in: app)
        XCTAssertTrue(bassLevelSlider.isHittable, "BASSLINE LEVEL slider should be scrolled into view")
        dragSlider(bassLevelSlider)

        scrollUntilHittable(generateBassButton, in: app)
        XCTAssertTrue(generateBassButton.isHittable, "GENERATE BASS button should be scrolled into view")
        generateBassButton.tap()

        saveScreenshot(app, name: "03b_bassline_enabled.png")

        // MARK: 4. Scroll down to GLOBAL ENV; SPACE/AGE/SPEED sliders exist & adjustable

        let spaceSlider = app.otherElements["spaceSlider"]
        scrollUntilHittable(spaceSlider, in: app)
        XCTAssertTrue(spaceSlider.exists, "SPACE slider should exist")
        XCTAssertTrue(spaceSlider.isHittable, "SPACE slider should be scrolled into view")

        let ageSlider = app.otherElements["ageSlider"]
        XCTAssertTrue(ageSlider.exists, "AGE slider should exist")

        // NOSTALGIA sits directly under AGE (SPEC.md Addendum 4 order:
        // SPACE, AGE, NOSTALGIA, SPEED) -- the Juno-106-style BBD chorus mix.
        let nostalgiaSlider = app.otherElements["nostalgiaSlider"]
        scrollUntilHittable(nostalgiaSlider, in: app)
        XCTAssertTrue(nostalgiaSlider.exists, "NOSTALGIA slider should exist")
        XCTAssertTrue(nostalgiaSlider.isHittable, "NOSTALGIA slider should be scrolled into view")

        let speedSlider = app.otherElements["speedSlider"]
        scrollUntilHittable(speedSlider, in: app)
        XCTAssertTrue(speedSlider.exists, "SPEED slider should exist")
        XCTAssertTrue(speedSlider.isHittable, "SPEED slider should be scrolled into view")

        saveScreenshot(app, name: "03_controls_lower.png")

        // Adjust the SPACE, NOSTALGIA, and SPEED sliders via a coordinate
        // drag (they're custom blocky faders, not UISliders, so we
        // synthesize the drag directly rather than relying on the
        // `adjustable` accessibility trait).
        dragSlider(spaceSlider)
        scrollUntilHittable(nostalgiaSlider, in: app)
        dragSlider(nostalgiaSlider)
        dragSlider(speedSlider)

        // MARK: 5. Enable LOFI BEATS -> LEVEL slider + GENERATE BEAT + LOOP readout appear

        let drumsToggle = app.buttons["drumsToggle"]
        scrollUntilHittable(drumsToggle, in: app)
        XCTAssertTrue(drumsToggle.exists, "DRUMS toggle should exist")
        drumsToggle.tap()

        let drumLevelSlider = app.otherElements["drumLevelSlider"]
        XCTAssertTrue(drumLevelSlider.waitForExistence(timeout: 3), "LEVEL slider should appear once LOFI BEATS is enabled")

        let generateBeatButton = app.buttons["generateBeatButton"]
        XCTAssertTrue(generateBeatButton.waitForExistence(timeout: 3), "GENERATE BEAT should appear once LOFI BEATS is enabled")

        let loopReadout = app.staticTexts["loopReadout"]
        XCTAssertTrue(loopReadout.waitForExistence(timeout: 3), "LOOP readout should appear once LOFI BEATS is enabled")

        // MARK: 6. Generate beat -> LOOP readout changes (regenerateBeat()
        // guarantees a different loop every time, so a single tap always
        // suffices -- no retry loop needed, unlike the melody readout).

        scrollUntilHittable(generateBeatButton, in: app)
        let initialLoop = loopReadout.label
        generateBeatButton.tap()
        let loopChanged = waitFor(timeout: 2) { loopReadout.label != initialLoop }
        XCTAssertTrue(loopChanged, "LOOP readout should change after tapping GENERATE BEAT (loop selection never repeats). was=\(initialLoop) now=\(loopReadout.label)")

        // 04_drums_enabled.png doubles as the "full lower half" screenshot
        // (DRUMS card + GENERATE BEAT are the bottom of the scrollable
        // stack at this point).
        saveScreenshot(app, name: "04_drums_enabled.png")

        // MARK: 7. RENDER & SHARE -> render screen -> completion -> share sheet

        let renderShareButton = app.buttons["renderShareButton"]
        scrollUntilHittable(renderShareButton, in: app)
        XCTAssertTrue(renderShareButton.exists, "RENDER & SHARE bar should exist")
        renderShareButton.tap()

        let encodingHeader = app.staticTexts["encodingHeaderText"]
        XCTAssertTrue(encodingHeader.waitForExistence(timeout: 5), "Render screen should appear after tapping RENDER & SHARE")
        XCTAssertTrue(encodingHeader.label.contains("ENCODING ANALOG SIGNAL"),
                      "Render header should read ENCODING ANALOG SIGNAL. Was: \(encodingHeader.label)")

        saveScreenshot(app, name: "05_render_screen.png")

        // Wait (generously) for the render to complete. LG_RENDER_SECONDS=8
        // keeps this fast in practice, but simulator video encoding can be
        // slow under load, so allow up to 90s.
        let doneButton = app.buttons["doneButton"]
        let renderFinished = doneButton.waitForExistence(timeout: 90)
        XCTAssertTrue(renderFinished, "Render should complete (DONE button should appear) within 90s")

        // The share sheet auto-presents the moment rendering completes.
        // Give it a moment to finish its presentation animation, then
        // screenshot whatever is on screen (share sheet if it showed).
        _ = waitFor(timeout: 2) { false }
        saveScreenshot(app, name: "06_share_sheet.png")

        dismissShareSheetIfPresent(app)

        // MARK: Return to main screen

        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "DONE button should still be present after dismissing the share sheet")
        doneButton.tap()

        XCTAssertTrue(header.waitForExistence(timeout: 5), "Should return to the main screen after tapping DONE")
    }

    /// Regression test for SPEC.md Addendum 5 item 1 ("deliberate slider
    /// editing"): a vertical drag that starts ON a slider must scroll the
    /// page, not change the slider's value. `LiminalSlider` now only begins
    /// tracking a drag once the first movement reads as clearly horizontal
    /// (`DragGesture(minimumDistance: 12)` + a latched |dx|>|dy| check on
    /// the first `onChanged`, applied via `.simultaneousGesture` so the
    /// ancestor ScrollView's own pan recognizer keeps receiving touches
    /// concurrently). This test drives that exact scenario via XCUITest
    /// coordinate APIs and checks both halves: the slider's reported
    /// accessibility value is unchanged, AND the slider's on-screen frame
    /// moved (proving the drag really did scroll the page rather than being
    /// silently swallowed).
    func testVerticalDragThroughSliderDoesNotChangeValue() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["LG_RENDER_SECONDS": "8"]
        app.launch()

        let header = app.staticTexts["mainHeaderTitle"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "Main header should appear after splash")

        let spaceSlider = app.otherElements["spaceSlider"]
        scrollUntilHittable(spaceSlider, in: app)
        XCTAssertTrue(spaceSlider.isHittable, "SPACE slider should be scrolled into view")

        // Set it to a known, non-edge value first via a clean horizontal
        // drag, so a regression that nudges the value in either direction
        // would be caught (rather than starting from an edge where a small
        // nudge might not move the reported/rounded value).
        dragSlider(spaceSlider, toNormalizedX: 0.5)
        let valueBefore = spaceSlider.value as? String
        let frameBefore = spaceSlider.frame

        saveScreenshot(app, name: "07_vertical_drag_before.png")

        // A vertical drag starting ON the slider: should scroll the page,
        // not move the slider's thumb.
        let start = spaceSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = spaceSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 6.0))
        start.press(forDuration: 0.05, thenDragTo: end)
        _ = waitFor(timeout: 0.5) { false } // let the scroll animation settle

        saveScreenshot(app, name: "08_vertical_drag_after.png")

        // Re-query by identifier (the element likely moved/scrolled) and
        // compare both its reported value and its on-screen frame.
        let spaceSliderAfter = app.otherElements["spaceSlider"]
        XCTAssertTrue(spaceSliderAfter.waitForExistence(timeout: 2), "SPACE slider should still exist after the vertical drag")

        XCTAssertEqual(spaceSliderAfter.value as? String, valueBefore,
                       "A vertical drag starting on the SPACE slider must not change its value. before=\(valueBefore ?? "nil") after=\(spaceSliderAfter.value as? String ?? "nil")")

        XCTAssertNotEqual(frameBefore.origin.y, spaceSliderAfter.frame.origin.y,
                          "The vertical drag should have scrolled the page (slider's on-screen position should move)")
    }

    // MARK: - Helpers

    /// Saves a screenshot both as an XCTAttachment (visible in the test
    /// report) and as a plain PNG file in the scratchpad uitest directory
    /// (the simulator shares the host filesystem, so this file is
    /// immediately readable from outside the test process).
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let fileURL = screenshotDir.appendingPathComponent(name)
        try? screenshot.pngRepresentation.write(to: fileURL)
    }

    /// Polls `condition` on the main run loop (via a short-lived
    /// expectation) until it returns true or `timeout` elapses.
    @discardableResult
    private func waitFor(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitFor(timeout: timeout) { element.exists && element.isHittable }
    }

    /// Scrolls the main scroll view up until `element` is hittable (or gives
    /// up after `maxSwipes`). Uses an explicit coordinate press-and-drag
    /// rather than `XCUIElement.swipeUp()`: the latter's default gesture
    /// duration is too fast to reliably register as a scroll against a
    /// SwiftUI `ScrollView` (it can register as a near-tap and get
    /// rubber-banded back to the top).
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 10) {
        guard !element.isHittable else { return }
        let scrollView = app.scrollViews.firstMatch
        let target = scrollView.exists ? scrollView : app
        var attempts = 0
        while !element.isHittable && attempts < maxSwipes {
            let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            start.press(forDuration: 0.05, thenDragTo: end)
            attempts += 1
            _ = waitFor(timeout: 0.3) { false }
        }
    }

    /// Drags the blocky analog slider (a custom SwiftUI drag-gesture
    /// control, not a UISlider) from its low end toward its high end.
    private func dragSlider(_ element: XCUIElement, toNormalizedX fraction: CGFloat = 0.85) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// The rendered clip's share sheet is a system `UIActivityViewController`
    /// presented in-process via SwiftUI's `.sheet`. Its exact control labels
    /// vary by iOS version, so try the common explicit dismiss controls
    /// first and fall back to an interactive swipe-down (which SwiftUI
    /// sheets support unless interactive dismissal is explicitly disabled,
    /// which `ShareSheet` does not do).
    private func dismissShareSheetIfPresent(_ app: XCUIApplication) {
        let closeCandidates = ["Close", "Cancel", "Done"]
        for label in closeCandidates {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 1), button.isHittable {
                button.tap()
                return
            }
        }
        // Fall back to a swipe-down dismissal gesture on the sheet.
        app.swipeDown()
    }
}
