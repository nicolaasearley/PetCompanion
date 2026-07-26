import SwiftUI

/// ON-02 Create account / ON-03 Sign in — one shared structure (doc 14 §4),
/// minimal email form with mock submit. Errors are inline and
/// non-destructive: input is retained and the error is announced.
struct AuthFormView: View {
    enum Mode {
        case createAccount
        case signIn

        var title: String {
            switch self {
            case .createAccount: "Create your account"
            case .signIn: "Welcome back"
            }
        }
    }

    let mode: Mode
    let onAuthenticated: (UserAccount) -> Void

    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xxl) {
                Text(mode.title)
                    .font(Font.pc.title)
                    .foregroundStyle(Color.pc.ink)
                    .accessibilityAddTraits(.isHeader)

                if mode == .createAccount {
                    Text("Each caregiver gets their own account — no shared passwords.")
                        .font(Font.pc.body)
                        .foregroundStyle(Color.pc.inkSecondary)
                }

                VStack(spacing: PCSpacing.lg) {
                    PCLabeledField(label: "Email") {
                        TextField("you@example.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    PCLabeledField(label: "Password") {
                        SecureField("At least 8 characters", text: $password)
                            .textContentType(mode == .createAccount ? .newPassword : .password)
                    }
                }

                // Inline, non-destructive error region.
                if let errorMessage {
                    PCInlineError(message: errorMessage)
                }

                PrimaryButton(
                    title: "Continue with email",
                    isLoading: isSubmitting,
                    action: submit
                )
            }
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() {
        guard !isSubmitting else { return }
        errorMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                let user: UserAccount
                switch mode {
                case .createAccount:
                    user = try await model.auth.createAccount(email: email, password: password)
                case .signIn:
                    user = try await model.auth.signIn(email: email, password: password)
                }
                onAuthenticated(user)
            } catch {
                let message = error.localizedDescription
                errorMessage = message
                // Announced via live region so screen-reader users hear the
                // validation result (ON-02/ON-03 a11y note).
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}

#Preview("ON-02 Create account") {
    NavigationStack {
        AuthFormView(mode: .createAccount, onAuthenticated: { _ in })
    }
    .environment(AppModel.mock())
}

#Preview("ON-03 Sign in") {
    NavigationStack {
        AuthFormView(mode: .signIn, onAuthenticated: { _ in })
    }
    .environment(AppModel.mock())
}
