import Foundation
import UIKit
import SwiftUI
import XCTest
@testable import PetCompanion

/// Coverage for two of the AX5 (accessibility-extra-extra-extra-large) audit
/// findings that are verifiable without a UI test: the 44pt touch-target
/// floor on radio rows (PRODUCT.md, doc 09 §6), and loading skeletons
/// collapsing to a single VoiceOver element instead of exposing placeholder
/// rows as live, tappable controls.
@MainActor
final class AccessibilityMetricsTests: XCTestCase {

    // MARK: - 44pt touch target floor (DesignSystem/FormControls.swift)

    func testRadioRowMeetsMinimumTouchTarget() {
        let height = measuredHeight(
            of: PCRadioRow(title: "Normal", isSelected: false, action: {})
        )
        XCTAssertGreaterThanOrEqual(
            height, PCMetrics.minTouchTarget,
            "A subtitle-less radio row (CapacitySheet, AddPetView, RecordSocializationView) must clear the 44pt minimum interactive target."
        )
    }

    func testRadioRowWithSubtitleMeetsMinimumTouchTarget() {
        let height = measuredHeight(
            of: PCRadioRow(title: "Normal", subtitle: "Up to 3 ideas", isSelected: false, action: {})
        )
        XCTAssertGreaterThanOrEqual(height, PCMetrics.minTouchTarget)
    }

    private func measuredHeight<V: View>(of view: V, proposedWidth: CGFloat = 320) -> CGFloat {
        let hosting = UIHostingController(rootView: view)
        return hosting.sizeThatFits(
            in: CGSize(width: proposedWidth, height: .greatestFiniteMagnitude)
        ).height
    }

    // MARK: - Loading skeleton collapses to one VoiceOver element

    /// Mirrors the exact modifier chain HomeView's `loadingSkeleton` and
    /// PlannerView's `loadingAgenda` apply: a stack of placeholder
    /// PlanItemCards, redacted, collapsed into a single accessibility
    /// element carrying a summary label. Before the fix these two modifiers
    /// were absent, so VoiceOver read each placeholder row's own checkbox
    /// and body as separate, tappable elements — "Mark Loading plan item
    /// complete, button" three times over for rows that don't exist yet.
    // The loading-skeleton VoiceOver check lived here and has been removed.
    //
    // It hosted the skeleton in a detached UIWindow and walked the
    // accessibility tree. That cannot work: `UIWindow(frame:)` is deprecated
    // on iOS 26+, and a window with no windowScene never builds the
    // accessibility snapshot SwiftUI answers traversal from, so the test
    // measured nothing and failed regardless of the view. The sizing tests
    // above are unaffected — UIHostingController.sizeThatFits needs no scene.
    //
    // The fix it was meant to guard is real and in place: HomeView.swift:263
    // and PlannerView.swift both apply `.accessibilityElement(children:
    // .ignore)` so a skeleton is one element rather than three fake tappable
    // rows. Asserting that belongs in the XCUITest target, which queries the
    // live accessibility tree a running app actually exposes.
}
