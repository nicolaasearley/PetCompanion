import SwiftUI

struct RequestPasswordResetView: View {
    let onBackToSignIn: () -> Void

    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var isSubmitting = false
    @State private var didRequestReset = false
    @State private var emailError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xxl) {
                if didRequestReset {
                    acknowledgement
                } else {
                    requestForm
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var requestForm: some View {
        Group {
            Text("Reset your password")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)

            Text("Enter the email you use for Settle. We'll send instructions if an account matches it.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            PCLabeledField(label: "Email", errorMessage: emailError) {
                TextField("you@example.com", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            PrimaryButton(
                title: "Send reset instructions",
                isLoading: isSubmitting,
                action: submit
            )
        }
    }

    private var acknowledgement: some View {
        Group {
            Image(systemName: "envelope.badge")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.pc.primary)
                .accessibilityHidden(true)

            Text("Next steps")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)

            Text("If we can match that address, recovery instructions may arrive shortly. For privacy, we can’t confirm whether an account exists or an email was sent.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.backendMode == .mock {
                Text("Demo mode does not send email. Open the review link to continue the recovery flow.")
                    .font(Font.pc.secondary)
                    .foregroundStyle(Color.pc.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecondaryButton(title: "Open demo reset link") {
                    Task {
                        await model.open(URL(string: "petcompanion://password-reset?mock=valid")!)
                    }
                }
            }

            PrimaryButton(title: "Back to sign in", action: onBackToSignIn)

            Button("Try another email") {
                didRequestReset = false
                emailError = nil
            }
            .font(Font.pc.body.weight(.medium))
            .foregroundStyle(Color.pc.primary)
            .frame(minHeight: PCMetrics.minTouchTarget)
            .frame(maxWidth: .infinity)
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        emailError = nil

        do {
            _ = try AuthValidation.normalizedEmail(email)
        } catch {
            emailError = AuthError.invalidEmail.localizedDescription
            AccessibilityNotification.Announcement(emailError!).post()
            return
        }

        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                _ = try await model.requestPasswordReset(email: email)
                didRequestReset = true
                AccessibilityNotification.Announcement("Password recovery next steps").post()
            } catch {
                let message = AuthError.invalidEmail.localizedDescription
                emailError = message
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}

struct SetNewPasswordView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isSubmitting = false
    @State private var passwordError: String?
    @State private var submissionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PCSpacing.xxl) {
                switch model.passwordRecoveryState {
                case .validating:
                    validating
                case .ready:
                    passwordForm
                case .invalid:
                    invalidLink
                case .signedInBlocked:
                    signedInBlocked
                case .complete:
                    completion
                case nil:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PCSpacing.screenMargin)
        }
        .background(Color.pc.bg.ignoresSafeArea())
    }

    private var validating: some View {
        Group {
            ProgressView()
                .tint(Color.pc.primary)
            Text("Checking your reset link…")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)
            Text("This should only take a moment.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
        }
    }

    private var passwordForm: some View {
        Group {
            Text("Choose a new password")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)

            Text("Use at least \(AuthValidation.minimumPasswordLength) characters.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: PCSpacing.lg) {
                PCLabeledField(label: "New password", errorMessage: passwordError) {
                    SecureField("At least \(AuthValidation.minimumPasswordLength) characters", text: $password)
                        .textContentType(.newPassword)
                }
                PCLabeledField(label: "Confirm new password") {
                    SecureField("Enter it again", text: $confirmation)
                        .textContentType(.newPassword)
                }
            }

            if let submissionError {
                PCInlineError(message: submissionError)
            }

            PrimaryButton(
                title: "Update password",
                isLoading: isSubmitting,
                action: updatePassword
            )

            Button("Cancel") {
                Task { await model.dismissPasswordRecovery() }
            }
            .font(Font.pc.body.weight(.medium))
            .foregroundStyle(Color.pc.primary)
            .frame(minHeight: PCMetrics.minTouchTarget)
            .frame(maxWidth: .infinity)
        }
    }

    private var invalidLink: some View {
        Group {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.pc.primary)
                .accessibilityHidden(true)
            Text("This link can’t be used")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)
            Text(AuthError.invalidRecoveryLink.localizedDescription)
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(
                title: "Request a new link",
                action: { Task { await model.dismissPasswordRecovery() } }
            )
        }
    }

    private var signedInBlocked: some View {
        Group {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.pc.primary)
                .accessibilityHidden(true)
            Text("You’re already signed in")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Return to Settle, then sign out before opening a password reset link. Your current account has not been changed.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(
                title: "Return to Settle",
                action: { Task { await model.dismissPasswordRecovery() } }
            )
        }
    }

    private var completion: some View {
        Group {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.pc.success)
                .accessibilityHidden(true)
            Text("Password updated")
                .font(Font.pc.title)
                .foregroundStyle(Color.pc.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Your new password is ready. Sign in to continue.")
                .font(Font.pc.body)
                .foregroundStyle(Color.pc.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(
                title: "Continue to sign in",
                action: { Task { await model.dismissPasswordRecovery() } }
            )
        }
    }

    private func updatePassword() {
        guard !isSubmitting else { return }
        passwordError = AuthValidation.passwordConfirmationError(
            password: password,
            confirmation: confirmation
        )
        submissionError = nil
        if let passwordError {
            AccessibilityNotification.Announcement(passwordError).post()
            return
        }

        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await model.completePasswordRecovery(password: password)
                password = ""
                confirmation = ""
                AccessibilityNotification.Announcement("Password updated").post()
            } catch {
                let message = (error as? AuthError)?.localizedDescription
                    ?? AuthError.passwordUpdateFailed.localizedDescription
                submissionError = message
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}
