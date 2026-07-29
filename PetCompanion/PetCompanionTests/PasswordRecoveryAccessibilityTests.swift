import SwiftUI
import UIKit
import XCTest
@testable import PetCompanion

@MainActor
final class PasswordRecoveryAccessibilityTests: XCTestCase {
    func testResetRequestScreenKeepsTouchTargetAndGrowsForDynamicType() {
        let model = AppModel.mock()
        let view = RequestPasswordResetView(onBackToSignIn: {})
            .environment(model)

        let standard = measuredHeight(of: view, dynamicTypeSize: .large)
        let accessibility = measuredHeight(of: view, dynamicTypeSize: .accessibility3)

        XCTAssertGreaterThanOrEqual(standard, PCMetrics.minTouchTarget)
        XCTAssertGreaterThan(
            accessibility,
            standard,
            "Recovery request copy and controls must reflow rather than truncate at accessibility sizes."
        )
    }

    func testSetPasswordScreenKeepsTouchTargetAndGrowsForDynamicType() async throws {
        let model = AppModel.mock()
        await model.open(
            try XCTUnwrap(URL(string: "petcompanion://password-reset?mock=valid"))
        )
        let view = SetNewPasswordView().environment(model)

        let standard = measuredHeight(of: view, dynamicTypeSize: .large)
        let accessibility = measuredHeight(of: view, dynamicTypeSize: .accessibility3)

        XCTAssertGreaterThanOrEqual(standard, PCMetrics.minTouchTarget)
        XCTAssertGreaterThan(
            accessibility,
            standard,
            "New-password fields and actions must grow rather than truncate at accessibility sizes."
        )
    }

    private func measuredHeight<V: View>(
        of view: V,
        dynamicTypeSize: DynamicTypeSize,
        proposedWidth: CGFloat = 280
    ) -> CGFloat {
        let hosting = UIHostingController(
            rootView: view.environment(\.dynamicTypeSize, dynamicTypeSize)
        )
        return hosting.sizeThatFits(
            in: CGSize(width: proposedWidth, height: .greatestFiniteMagnitude)
        ).height
    }
}
