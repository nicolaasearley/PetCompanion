import CoreGraphics
import UIKit
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

    /// Always non-nil, deliberately.
    ///
    /// The obvious design is for `standard` to pass nothing and inherit the
    /// device. That is a trap: this simulator was already sitting at an
    /// enlarged text size, so an inherited "default" baseline was rendering
    /// at roughly AX1 and a reviewer comparing it against AX5 would have
    /// concluded the app barely reflows. Both variants now state their size,
    /// so a comparison is between two known quantities.
    var contentSizeCategoryName: String {
        switch self {
        case .standard: "UICTContentSizeCategoryL"
        case .ax5: "UICTContentSizeCategoryAccessibilityXXXL"
        }
    }
}

/// Light or dark appearance.
///
/// **This is a device setting, not a launch argument.** Passing
/// `-UIUserInterfaceStyle Dark` was tried first and it does nothing on iOS
/// 27: the app rendered light and the two screenshots differed by 0.05% of
/// their pixels, which was the clock. The argument is still passed because it
/// is harmless, but the thing that actually works is
///
///     xcrun simctl ui booted appearance dark
///
/// run before `xcodebuild`. `ReviewDriver` measures what was actually
/// rendered and says so, so a run can never quietly claim an appearance it
/// did not have.
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

    /// Where PNGs go.
    ///
    /// A plain constant rather than an environment override: `TEST_RUNNER_`
    /// values do not reach the runner under `xcodebuild test` here, so an
    /// "override" would have been documented, accepted, and ignored.
    static let outputRoot = URL(fileURLWithPath: "/tmp/petcompanion-ui", isDirectory: true)

    init(
        scenario: String,
        testCase: XCTestCase,
        textSize: ReviewTextSize,
        appearance: ReviewAppearance
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

        let arguments = [
            "-PetCompanionBackend", "mock",
            "-UIPreferredContentSizeCategoryName", textSize.contentSizeCategoryName,
            "-UIUserInterfaceStyle", appearance.userInterfaceStyleArgument,
        ]
        app.launchArguments = arguments
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "PetCompanion never reached the foreground; nothing downstream is meaningful."
        )
        note("launch arguments: \(arguments.joined(separator: " "))")
        recordRenderedAppearance()
    }

    // MARK: - Capture

    /// Screenshots the whole screen, attaches it, and writes a PNG.
    /// Returns the PNG path so a test can log it.
    ///
    /// The keyboard is put away first. That is not cosmetic: the QuickType
    /// bar above it (`SystemInputAssistantView`) is where iOS offers saved
    /// AutoFill credentials, and it was rendering a real address into form
    /// screenshots. It also means a reviewer sees the whole form instead of
    /// the top half of one.
    ///
    /// Refuses to write anything still showing an email address the harness
    /// did not type. See `foreignEmailAddressesOnScreen()`.
    @discardableResult
    func capture(_ name: String, dismissingKeyboard: Bool = true) -> URL? {
        // A system prompt in a screenshot tells a reviewer nothing about this
        // app and hides the screen that was meant to be reviewed.
        dismissSystemPrompt()
        if dismissingKeyboard { dismissKeyboard() }

        let intruders = foreignEmailAddressesOnScreen()
        guard intruders.isEmpty else {
            note(
                "REFUSED to capture \"\(name)\": the screen is showing "
                    + "\(intruders.count) address(es) the harness never typed. "
                    + "Reset the simulator keychain (see README) and re-run."
            )
            return nil
        }

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

    /// Measures the appearance the app is actually rendering and says so.
    ///
    /// A launch argument that silently does nothing is the worst possible
    /// outcome for a review harness: a folder named `-dark` full of light
    /// screenshots would have a reviewer sign off on a dark theme nobody
    /// looked at. `-UIUserInterfaceStyle` is exactly that argument on iOS 27,
    /// so the rendered result is measured rather than assumed.
    private func recordRenderedAppearance() {
        guard let rendered = renderedAppearance() else {
            note("could not measure the rendered appearance")
            return
        }
        if rendered == appearance {
            note("rendered appearance: \(rendered.rawValue) (measured, matches the request)")
        } else {
            note(
                "WARNING — requested \(appearance.rawValue) but the app rendered "
                    + "\(rendered.rawValue). The screenshots in this folder are "
                    + "\(rendered.rawValue), whatever the folder name says. Appearance is a "
                    + "device setting: run `xcrun simctl ui booted appearance \(appearance.rawValue)` "
                    + "before xcodebuild."
            )
        }
    }

    /// Average luminance of the whole screen, bucketed to light or dark.
    ///
    /// Averaging the entire screenshot is crude but decisive: this app's two
    /// themes are a near-white and a near-black background, and text occupies
    /// a small fraction of the pixels either way.
    func renderedAppearance() -> ReviewAppearance? {
        guard let source = XCUIScreen.main.screenshot().image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let luminance =
            (0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])) / 255
        return luminance > 0.5 ? .light : .dark
    }

    /// Every email address currently on screen that the harness did not put
    /// there itself.
    ///
    /// This exists because of a real incident, not as a theoretical control.
    /// iOS offered a saved iCloud Keychain credential over the password
    /// field and rendered the machine owner's actual personal address into a
    /// screenshot. Screenshots are the whole output of this harness and get
    /// read and passed around, so a capture showing someone's real address is
    /// a leak, not a cosmetic defect.
    ///
    /// The fix is to reset the simulator keychain so AutoFill has nothing to
    /// offer (see README). This check is the backstop that makes a
    /// regression loud instead of silent.
    func foreignEmailAddressesOnScreen() -> [String] {
        let expected: Set<String> = [
            AppNavigator.reviewerEmail,
            "you@example.com", // the app's own placeholder text
        ]
        let containsAt = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "@", "@")
        let candidates = app.staticTexts.matching(containsAt).allElementsBoundByIndex
            + app.textFields.matching(containsAt).allElementsBoundByIndex
            + app.buttons.matching(containsAt).allElementsBoundByIndex

        var found: Set<String> = []
        for element in candidates {
            for text in [element.label, element.value as? String].compactMap({ $0 }) {
                for address in Self.emailAddresses(in: text) where !expected.contains(address) {
                    found.insert(address)
                }
            }
        }
        return found.sorted()
    }

    private static func emailAddresses(in text: String) -> [String] {
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
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
            "text size: \(textSize.rawValue) (\(textSize.contentSizeCategoryName))",
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
        guard makeHittable(element) else {
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
    ///
    /// The keyboard raised by the *previous* field is what usually hides the
    /// next one, so it is put away before this field is looked for.
    @discardableResult
    func type(_ text: String, into field: XCUIElement, describedAs description: String) -> Bool {
        guard field.waitForExistence(timeout: 12) else {
            note("never appeared: \(description)")
            return false
        }
        guard makeHittable(field) else {
            note("found but not tappable: \(description)")
            return false
        }

        // Two separate hazards, both hit on the second field of a form:
        //
        //  * typing while the keyboard is still animating in silently drops
        //    the text, so the keyboard is waited for and the result checked;
        //  * `XCUIElement.tap()` on this app's SecureField lands but does not
        //    move focus, so a tap at the element's own centre coordinate is
        //    the second attempt. That is derived from the element's frame,
        //    not guessed at from screen proportions.
        for attempt in 1...3 {
            if attempt == 2 {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                field.tap()
            }
            declinePasswordAutoFill()
            guard app.keyboards.element.waitForExistence(timeout: 5) else {
                note("keyboard never came up for \(description); has keyboard focus: \(field.hasFocus)")
                continue
            }
            clearExistingText(in: field)
            field.typeText(text)
            if contents(of: field, match: text) { return true }
            note("input did not stick on attempt \(attempt): \(description)")
        }
        note("could not enter text into \(description)")
        return false
    }

    /// Secure fields report their contents as bullets, so a length match is
    /// the most a black-box driver can confirm for one.
    private func contents(of field: XCUIElement, match text: String) -> Bool {
        guard let value = field.value as? String else { return false }
        if value == field.placeholderValue { return false }
        return value == text || value.count == text.count
    }

    private func clearExistingText(in field: XCUIElement) {
        guard let existing = field.value as? String,
              !existing.isEmpty,
              existing != field.placeholderValue
        else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
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
        dumpElementTreeIfRequested(reason: "screen never appeared: \(description)")
        return false
    }

    /// Set to true while debugging a scenario that will not advance.
    ///
    /// Off by default because it is hundreds of lines per failure, but when a
    /// screen does not arrive the tree is the entire explanation — every
    /// blocker found while building this harness (the strong-password panel,
    /// the QuickType suggestion, the save-password alert) was invisible in
    /// the logs and obvious in the tree. Not an environment variable: see the
    /// note in `ReviewScenarioCase` about `TEST_RUNNER_` values not arriving.
    static let dumpsElementTree = false

    func dumpElementTreeIfRequested(reason: String) {
        guard Self.dumpsElementTree else { return }
        print("PC_UI_TREE ---- \(reason) ----\n\(app.debugDescription)\nPC_UI_TREE ---- end ----")
    }

    /// Dismisses a system prompt sitting over the app, declining it.
    ///
    /// After the account form submits, iOS offers "Save Password?". It is
    /// modal, so it blocks the next step, and the only acceptable answer here
    /// is "Not Now": saving would write a credential into the simulator
    /// keychain, which is precisely the state that later produces AutoFill
    /// suggestions in screenshots.
    ///
    /// The affirmative buttons are deliberately absent from this list. This
    /// helper can only ever decline.
    @discardableResult
    func dismissSystemPrompt() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Springboard alerts are unambiguously the system's, so generic
        // titles are safe there. The app's own alerts are deliberately NOT
        // searched this way: HM-01's quick-add alert has a "Cancel" button,
        // and dismissing it here would close the very screen the scenario
        // was about to photograph.
        let springboardAlert = springboard.alerts.firstMatch
        if springboardAlert.exists {
            let label = springboardAlert.label
            for title in ["Not Now", "Don't Allow", "Dismiss", "Cancel", "Close"] {
                let button = springboardAlert.buttons[title]
                if button.exists, button.isHittable {
                    button.tap()
                    note("declined the system prompt “\(label)” with “\(title)”")
                    return true
                }
            }
            note("a system prompt “\(label)” appeared with no safe way to decline it")
        }

        // "Save Password?" is not published as an alert — it is a plain
        // window in the app's own hierarchy, so it can only be matched by
        // button title. These two titles appear nowhere in this app.
        for title in ["Not Now", "Don't Allow"] {
            for source in [app, springboard] {
                let button = source.buttons[title]
                if button.exists, button.isHittable {
                    button.tap()
                    note("declined a system prompt with “\(title)”")
                    return true
                }
            }
        }
        return false
    }

    /// Declines the system "Use Strong Password?" panel.
    ///
    /// ON-02's password field declares `.newPassword`, so iOS puts its
    /// AutoFill panel up *instead of* the keyboard. The field is focused the
    /// whole time, which is what made this look like a dropped tap: the
    /// keyboard query simply never became true. Declining hands the field
    /// back to the normal keyboard.
    ///
    /// The harness always declines rather than accepting the generated
    /// password: it types its own obviously-synthetic value, and it has no
    /// business saving anything into the Passwords app.
    func declinePasswordAutoFill() {
        guard app.staticTexts["Use Strong Password?"].exists else { return }
        let close = app.buttons["xmark"]
        guard close.waitForExistence(timeout: 2), close.isHittable else {
            note("the “Use Strong Password?” panel appeared but could not be closed")
            return
        }
        close.tap()
        note("declined the system “Use Strong Password?” panel on the password field")
    }

    /// Clears whatever is covering `element`, and waits for it to settle.
    ///
    /// Written as a retry loop rather than a straight sequence because the
    /// obstruction is often still animating. The "Save Password?" alert in
    /// particular arrives a beat after the screen it covers, so a single
    /// check could look past it, find the field un-hittable, and give up
    /// while the alert was mid-dismissal.
    func makeHittable(_ element: XCUIElement, attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            if element.isHittable { return true }

            if dismissSystemPrompt(), waitUntilHittable(element, timeout: 3) {
                return true
            }
            dismissKeyboard()
            if element.isHittable { return true }

            scrollToReveal(element)
            if waitUntilHittable(element, timeout: 1) { return true }
        }
        return element.isHittable
    }

    /// Polls `isHittable`. There is no `waitForHittable` on `XCUIElement`,
    /// and `waitForExistence` is not the same question.
    @discardableResult
    func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.isHittable { return true }
            _ = XCTWaiter.wait(for: [expectationNeverFulfilled()], timeout: 0.2)
        } while Date() < deadline
        return element.isHittable
    }

    /// Puts the software keyboard away.
    ///
    /// Return resigns first responder for the plain single-line fields this
    /// app uses. There is deliberately no blind coordinate-tap fallback: a
    /// guessed tap is how a driver ends up on a screen it did not mean to
    /// open and screenshots it as if nothing happened.
    func dismissKeyboard() {
        guard app.keyboards.element.exists else { return }
        app.typeText("\n")
        if app.keyboards.element.waitForNonExistence(timeout: 3) { return }
        note("keyboard would not dismiss; later steps may be covered by it")
    }

    /// The main content scroller.
    ///
    /// Not `app.scrollViews.firstMatch`: the keyboard contributes its own
    /// small scroll views, and index order put one of those first, so swipes
    /// were being delivered to a 44pt strip inside the keyboard instead of to
    /// the form. Choosing by area is what makes this reliable.
    var primaryScrollContainer: XCUIElement? {
        let candidates = app.scrollViews.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
        return candidates
            .filter { $0.exists && $0.frame.height > 200 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Scrolls the main container until `element` is hittable.
    func scrollToReveal(_ element: XCUIElement, maxSwipes: Int = 8) {
        guard let container = primaryScrollContainer else { return }
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
    /// Scrolls the main container down by `swipes` screenfuls.
    func scrollDown(_ swipes: Int = 1) {
        guard let container = primaryScrollContainer else { return }
        for _ in 0..<swipes { container.swipeUp() }
    }

    func scrollToTop(maxSwipes: Int = 8) {
        guard let container = primaryScrollContainer else { return }
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
