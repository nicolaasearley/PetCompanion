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
    private func loadingSkeletonFixture(label: String) -> some View {
        VStack(spacing: PCSpacing.betweenCards) {
            ForEach(0..<3, id: \.self) { _ in
                PlanItemCard(title: "Loading plan item", meta: "Loading")
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    func testLoadingSkeletonExposesExactlyOneAccessibilityElement() {
        let label = "Loading today's plan"
        let hosting = UIHostingController(rootView: loadingSkeletonFixture(label: label))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        // SwiftUI builds its accessibility snapshot off the layout pass; give
        // it a runloop turn before reading it back.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let leaves = accessibleLeaves(in: hosting.view)

        XCTAssertEqual(
            leaves.count, 1,
            "The skeleton must expose exactly one VoiceOver element, not one per placeholder row. Found: \(leaves.map { $0.accessibilityLabel ?? "<no label>" })"
        )
        XCTAssertEqual(leaves.first?.accessibilityLabel, label)

        window.isHidden = true
    }

    /// Depth-first search for the accessibility leaves a node exposes,
    /// following the same traversal VoiceOver uses: `isAccessibilityElement`
    /// marks a leaf (recursion stops there); otherwise the
    /// `UIAccessibilityContainer` methods are consulted directly — SwiftUI's
    /// hosting view answers `accessibilityElementCount()` /
    /// `accessibilityElement(at:)` from its own private accessibility tree
    /// rather than by populating the `accessibilityElements` property, so
    /// those methods (bridged via `AXContainerBridge`, matched by selector
    /// rather than declared conformance) are called explicitly; only then
    /// does traversal fall back to `subviews`.
    private func accessibleLeaves(in node: NSObject) -> [NSObject] {
        if node.isAccessibilityElement {
            return [node]
        }
        if let container = node as? AXContainerBridge {
            let count = container.accessibilityElementCount()
            if count > 0 {
                var results: [NSObject] = []
                for index in 0..<count {
                    if let raw = container.accessibilityElement(at: index), let obj = raw as? NSObject {
                        results.append(contentsOf: accessibleLeaves(in: obj))
                    }
                }
                return results
            }
        }
        if let view = node as? UIView {
            return view.subviews.flatMap { accessibleLeaves(in: $0) }
        }
        return []
    }
}

/// Matched by selector, not declared conformance, so it also bridges to
/// SwiftUI's private accessibility-node classes that implement
/// `UIAccessibilityContainer`'s methods without going through the
/// `accessibilityElements` stored-property path.
@objc private protocol AXContainerBridge {
    func accessibilityElementCount() -> Int
    func accessibilityElement(at index: Int) -> Any?
}
