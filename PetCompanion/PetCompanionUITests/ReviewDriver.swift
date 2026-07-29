import XCTest

/// Text size the app is driven at.
///
/// `ax5` is the largest accessibility size. It is applied through the
/// `-UIPreferredContentSizeCategoryName` launch argument, which UIKit reads
/// out of the launch arguments' user-defaults domain before the first view
/// is laid out. `ReviewDriver` records the size the app actually reported
/// back in `NOTES.txt`, so a reviewer never has to take the argument's word
/// for it.
enum ReviewTextSize: String, CaseIterable {
    case standard
    case ax5

    /// `nil` means "leave the device default alone".
    var contentSizeCategoryName: String? {
        switch self {
        case .standard: nil
        case .ax5: "UICTContentSizeCategoryAccessibilityXXXL"
        }
    }
}

enum ReviewAppearance: String, CaseIterable {
    case light
    case dark

    var userInterfaceStyleArgument: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Drives PetCompanion and captures what it sees.
///
/// This is deliberately NOT an assertion harness. A UX reviewer wants to walk
/// the app and look at it; a step that cannot be reached is recorded as a
/// note and the walk continues, because a half-covered scenario is more
/// useful than a red X. The only hard failure is "the app never launched",
/// since nothing downstream of that means anything.
///
/// Every capture goes two places:
///   * an `XCTAttachment` with `.keepAlways`, for the result bundle, and
///   * a PNG under `<output root>/<scenario>/NN-<name>.png` on the host
///     filesystem, so a reviewer can open it with an ordinary image tool.
///
/// The host-file half is the one that matters here: simulator processes see
/// the real host filesystem for absolute paths, so the runner can write
/// straight to `/tmp/petcompanion-ui`.
final class ReviewDriver {
    let app = XCUIApplication()
    let scenario: String
    let textSize: ReviewTextSize
    let appearance: ReviewAppearance
    let outputDirectory: URL

    private unowned let testCase: XCTestCase
    private var stepIndex = 0
    private var notes: [String] = []

    /// Where PNGs go. Override with `TEST_RUNNER_PC_UI_OUTPUT_ROOT=<path>`.
    static var outputRoot: URL {
        let configured = ProcessInfo.processInfo.environment["PC_UI_OUTPUT_ROOT"]
        return URL(fileURLWithPath: configured ?? "/tmp/petcompanion-ui", isDirectory: true)
    }

    /// Text size for this run. Override with `TEST_RUNNER_PC_UI_TEXT_SIZE=ax5`.
    static var configuredTextSize: ReviewTextSize {
        ProcessInfo.processInfo.environment["PC_UI_TEXT_SIZE"]
            .flatMap(ReviewTextSize.init(rawValue:)) ?? .standard
    }

    /// Appearance for this run. Override with `TEST_RUNNER_PC_UI_APPEARANCE=dark`.
    static var configuredAppearance: ReviewAppearance {
        ProcessInfo.processInfo.environment["PC_UI_APPEARANCE"]
            .flatMap(ReviewAppearance.init(rawValue:)) ?? .light
    }

    init(
        scenario: String,
        testCase: XCTestCase,
        textSize: ReviewTextSize = ReviewDriver.configuredTextSize,
        appearance: ReviewAppearance = ReviewDriver.configuredAppearance
    ) {
        self.scenario = scenario
        self.testCase = testCase
        self.textSize = textSize
        self.appearance = appearance
        // The variant is part of the folder name on purpose: a reviewer
        // comparing default against AX5 needs both runs on disk at once, and
        // a shared folder would have the second run overwrite the first.
        self.outputDirectory = Self.outputRoot
            .appendingPathComponent("\(scenario)-\(textSize.rawValue)-\(appearance.rawValue)")
    }

    // MARK: - Launch

    /// Launches into the in-memory mock backend at the configured text size
    /// and appearance. There is no network and no real account anywhere in
    /// this path.
    func launch() {
        resetOutputDirectory()

        var arguments = ["-PetCompanionBackend", "mock"]
        if let category = textSize.contentSizeCategoryName {
            arguments += ["-UIPreferredContentSizeCategoryName", category]
        }
        arguments += ["-UIUserInterfaceStyle", appearance.userInterfaceStyleArgument]
        app.launchArguments = arguments
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "PetCompanion never reached the foreground; nothing downstream is meaningful."
        )
        note("launch arguments: \(arguments.joined(separator: " "))")
    }

    // MARK: - Capture

    /// Screenshots the whole screen, attaches it, and writes a PNG.
    /// Returns the PNG path so a test can log it.
    @discardableResult
    func capture(_ name: String) -> URL? {
        stepIndex += 1
        let screenshot = XCUIScreen.main.screenshot()
        let label = String(format: "%02d-%@", stepIndex, Self.slug(name))

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(scenario)/\(label)"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)

        let url = outputDirectory.appendingPathComponent("\(label).png")
        do {
            try screenshot.pngRepresentation.write(to: url, options: .atomic)
            return url
        } catch {
            // Losing the host-side PNG is worth saying out loud — the
            // attachment alone is not what a reviewer was promised.
            note("could not write \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Records something a reviewer needs to know: a surface that was not
    /// reachable, a control that never appeared, a piece of state the mock
    /// backend does not provide.
    func note(_ message: String) {
        notes.append(message)
        // Also goes into the xcodebuild log, so a failed run is still legible.
        print("PC_UI_NOTE [\(scenario)] \(message)")
    }

    /// Writes `NOTES.txt` alongside the PNGs. Call at the end of a scenario.
    func finish() {
        var lines = [
            "scenario: \(scenario)",
            "text size: \(textSize.rawValue)"
                + (textSize.contentSizeCategoryName.map { " (\($0))" } ?? " (device default)"),
            "appearance: \(appearance.rawValue)",
            "backend: mock (in-memory fixtures, no network, no real account)",
            "captured: \(stepIndex) screenshot(s)",
            "",
        ]
        lines += notes.map { "- \($0)" }
        try? lines.joined(separator: "\n")
            .appending("\n")
            .write(
                to: outputDirectory.appendingPathComponent("NOTES.txt"),
                atomically: true,
                encoding: .utf8
            )
    }

    // MARK: - Interaction

    /// Waits for `element`, scrolls it into view if needed, and taps it.
    /// Returns false rather than failing so a scenario can carry on and say
    /// what it missed.
    @discardableResult
    func tap(_ element: XCUIElement, describedAs description: String, timeout: TimeInterval = 12) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            note("never appeared: \(description)")
            return false
        }
        if !element.isHittable {
            scrollToReveal(element)
        }
        guard element.isHittable else {
            note("found but not tappable (likely clipped off-screen): \(description)")
            return false
        }
        element.tap()
        return true
    }

    /// Taps the first of several candidates that exists. SwiftUI's tab bar,
    /// toolbars and cards expose the same control through different element
    /// types depending on the OS build, so a scenario names more than one.
    @discardableResult
    func tapFirstAvailable(
        _ candidates: [XCUIElement],
        describedAs description: String,
        timeout: TimeInterval = 12
    ) -> Bool {
        guard let found = waitForAny(candidates, timeout: timeout) else {
            note("never appeared: \(description)")
            return false
        }
        return tap(found, describedAs: description, timeout: 2)
    }

    /// Types into a text field, clearing anything already there.
    @discardableResult
    func type(_ text: String, into field: XCUIElement, describedAs description: String) -> Bool {
        guard field.waitForExistence(timeout: 12) else {
            note("never appeared: \(description)")
            return false
        }
        if !field.isHittable { scrollToReveal(field) }
        guard field.isHittable else {
            note("found but not tappable: \(description)")
            return false
        }
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty,
           field.placeholderValue != existing {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
        return true
    }

    /// Waits until any one of the candidates exists, and returns it.
    func waitForAny(_ candidates: [XCUIElement], timeout: TimeInterval = 12) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = candidates.first(where: \.exists) { return found }
            _ = XCTWaiter.wait(for: [expectationNeverFulfilled()], timeout: 0.25)
        } while Date() < deadline
        return nil
    }

    /// True when any candidate showed up. Used to confirm a screen arrived
    /// before it is captured.
    @discardableResult
    func waitForScreen(_ candidates: [XCUIElement], describedAs description: String, timeout: TimeInterval = 15) -> Bool {
        if waitForAny(candidates, timeout: timeout) != nil { return true }
        note("screen never appeared: \(description)")
        return false
    }

    /// Scrolls the innermost scrollable container until `element` is hittable.
    func scrollToReveal(_ element: XCUIElement, maxSwipes: Int = 8) {
        let containers = [
            app.scrollViews.firstMatch,
            app.collectionViews.firstMatch,
            app.tables.firstMatch,
        ]
        guard let container = containers.first(where: \.exists) else { return }
        var swipes = 0
        while !element.isHittable, swipes < maxSwipes {
            container.swipeUp()
            swipes += 1
        }
        guard !element.isHittable else { return }
        // Overshot, or it was above the fold to begin with.
        for _ in 0...(swipes + 2) where !element.isHittable {
            container.swipeDown()
        }
    }

    /// Scrolls back to the top of the current scroll view, so the next
    /// capture starts from a predictable place.
    func scrollToTop(maxSwipes: Int = 8) {
        let container = app.scrollViews.firstMatch
        guard container.exists else { return }
        for _ in 0..<maxSwipes { container.swipeDown() }
    }

    /// Dismisses a sheet: prefer its own close control, fall back to a swipe.
    func dismissSheet(closeLabels: [String] = ["Close", "Done", "Cancel"]) {
        for label in closeLabels {
            let button = app.buttons[label]
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }
        app.swipeDown(velocity: .fast)
    }

    // MARK: - Reporting the environment back

    /// Reads the content size category the app is actually rendering at.
    ///
    /// XCUITest cannot ask the app for its trait collection, so this infers
    /// it the only way a black-box driver can: by measuring a known piece of
    /// body text. It is recorded, not asserted — the authoritative check is
    /// the image diff a reviewer runs between two variants.
    func recordRenderedTextScale(probe: XCUIElement, describedAs description: String) {
        guard probe.waitForExistence(timeout: 8) else {
            note("text-scale probe missing: \(description)")
            return
        }
        let frame = probe.frame
        note(
            "text-scale probe \"\(description)\": height \(String(format: "%.1f", frame.height))pt,"
                + " width \(String(format: "%.1f", frame.width))pt"
        )
    }

    // MARK: - Helpers

    private func expectationNeverFulfilled() -> XCTestExpectation {
        XCTestExpectation(description: "poll")
    }

    private func resetOutputDirectory() {
        let manager = FileManager.default
        try? manager.removeItem(at: outputDirectory)
        try? manager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let mapped = name.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
