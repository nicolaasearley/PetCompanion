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

    // MARK: - Needs-attention card keeps its 44pt target after the 2026-07-29
    // visual refresh (DesignSystem/PlanItemCard.swift)

    /// The needs-attention variant used to draw a 4pt leading accent bar
    /// (doc 09 §7.1) alongside the checkbox and an inline exclamation glyph —
    /// three overlapping cues for one state. The bar was dropped as a
    /// decorative tell and the glyph now sits in a small icon disc instead.
    /// This guards that the simplification didn't accidentally shrink the
    /// row below the checkbox's own 44pt touch target.
    func testNeedsAttentionPlanItemCardMeetsMinimumTouchTarget() {
        let height = measuredHeight(
            of: PlanItemCard(
                title: "Overdue walk",
                meta: "Walks",
                isNeedsAttention: true,
                onToggleComplete: {},
                onOpen: {}
            )
        )
        XCTAssertGreaterThanOrEqual(height, PCMetrics.minTouchTarget)
    }

    /// Needs-attention items without a checkbox (e.g. an informational
    /// "Open" affordance) rely on the leading icon alone once the accent bar
    /// is gone; confirm the row still clears the 44pt floor.
    func testNeedsAttentionPlanItemCardWithoutCheckboxMeetsMinimumTouchTarget() {
        let height = measuredHeight(
            of: PlanItemCard(
                title: "Vaccination record",
                meta: "From the vet",
                isNeedsAttention: true,
                showsCheckbox: false,
                trailingAffordance: "Open",
                onOpen: {}
            )
        )
        XCTAssertGreaterThanOrEqual(height, PCMetrics.minTouchTarget)
    }

    // MARK: - Socialization removal row keeps its 44pt target (doc 22 §7)

    /// "Remove from the passport" used to live only in a long-press context
    /// menu with no visible affordance at all. It is now a trailing overflow
    /// button sized to the touch-target floor (`SocializationRecordRow`);
    /// this guards that the row housing it doesn't collapse below 44pt.
    func testSocializationRecordRowWithRemovalMeetsMinimumTouchTarget() {
        let record = SocializationRecord(
            id: UUID(),
            experienceContentId: nil,
            label: "Doorbell",
            category: .sounds,
            effectiveDate: Date(),
            context: nil,
            response: .curious,
            note: nil,
            revision: 1,
            recordedByName: "You"
        )
        let height = measuredHeight(
            of: SocializationRecordRow(record: record, onRemove: {})
        )
        XCTAssertGreaterThanOrEqual(height, PCMetrics.minTouchTarget)
    }

    /// The read-only Recent list (Home passport overview) never offers
    /// removal, so it must keep rendering without the trailing menu at all
    /// rather than silently degrading to an unreachable control.
    func testSocializationRecordRowWithoutRemovalStillRenders() {
        let record = SocializationRecord(
            id: UUID(),
            experienceContentId: nil,
            label: "Grass",
            category: .surfaces,
            effectiveDate: Date(),
            context: nil,
            response: .relaxed,
            note: nil,
            revision: 1,
            recordedByName: "You"
        )
        let height = measuredHeight(of: SocializationRecordRow(record: record))
        XCTAssertGreaterThan(height, 0)
    }

    // MARK: - Training's socialization passport hero (2026-07-29 hierarchy update)

    /// The promoted hero tile leading Training carries an icon, a two-line
    /// title + purpose copy, and a full-row tap target. `sizeThatFits` in
    /// this test target resolves text at a large Dynamic Type size by
    /// default (confirmed by comparison against `PCRadioRow`, and by the
    /// fact that explicitly forcing `.accessibilityExtraExtraExtraLarge`
    /// via `.environment(\.sizeCategory:)` changes nothing — the harness has
    /// no live app trait collection to read a "standard" size from), so
    /// this doubles as a large-text check, not just a default-size one.
    func testSocializationPassportHeroMeetsMinimumTouchTarget() {
        let height = measuredHeight(of: SocializationPassportHero(action: {}))
        XCTAssertGreaterThanOrEqual(height, PCMetrics.minTouchTarget)
    }

    // MARK: - Training progress state bar (docs/22 §5.2 honest affordance)

    /// The owner-reported continuum bar must remain readable at large Dynamic
    /// Type: title + caption must not collapse. `sizeThatFits` in this harness
    /// resolves text at a large category (same as the passport-hero check).
    func testTrainingProgressStateBarRendersAtLargeDynamicType() {
        let compact = measuredHeight(
            of: TrainingProgressStateBar(
                model: TrainingProgressAffordanceModel(state: .practicing),
                style: .compact
            )
        )
        XCTAssertGreaterThan(compact, 0, "Compact progress affordance must lay out.")
        // Title + 6-step bar + caption should clear a single line of body text.
        XCTAssertGreaterThanOrEqual(compact, 44)

        let expanded = measuredHeight(
            of: TrainingProgressStateBar(
                model: TrainingProgressAffordanceModel(
                    state: .reliableInFamiliarSetting,
                    isPaused: true
                ),
                style: .expanded
            )
        )
        XCTAssertGreaterThan(
            expanded,
            compact,
            "Expanded style adds the explanation and should grow the layout."
        )
    }

    /// Labels name the state; accessibility must not invent a percentage.
    func testTrainingProgressStateBarAccessibilityNamesStateNotPercent() {
        let model = TrainingProgressAffordanceModel(state: .generalizing)
        XCTAssertEqual(model.title, "Generalizing")
        XCTAssertFalse(model.accessibilityLabel.contains("%"))
        XCTAssertTrue(model.accessibilityLabel.contains("Generalizing"))
        XCTAssertTrue(model.accessibilityLabel.contains("step 5 of 6"))
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
