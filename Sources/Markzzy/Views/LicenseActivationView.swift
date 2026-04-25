import SwiftUI

struct LicenseActivationView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var license: LicenseManager

    @State private var step: Step = .email
    @State private var email: String = ""
    @State private var isBusy: Bool = false
    @FocusState private var emailFocused: Bool

    private enum Step { case welcome, email, sent }

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(alignment: .leading, spacing: 14) {
                headerBar

                VStack(alignment: .leading, spacing: 6) {
                    Text(headerTitle)
                        .font(.title2.weight(.semibold))
                    Text(headerSubtitle)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if license.status == .expired {
                    Label(model.t(.licenseExpired), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .email:   emailStep
                    case .sent:    sentStep
                    }
                }

                if let err = license.lastError {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 0)
        }
        .frame(width: 440, height: 380)
        .onAppear {
            if email.isEmpty, !license.pendingEmail.isEmpty {
                email = license.pendingEmail
            }
            if step == .email, license.hasRememberedEmail {
                step = .welcome
            }
            if step == .email {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    emailFocused = true
                }
            }
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            // Subtle brand-tinted glow at the top to ground the logo.
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.clear,
                ],
                center: .top,
                startRadius: 0,
                endRadius: 220
            )
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            LogoMark(size: 26)
            Text("Markzzy")
                .font(.system(size: 20, weight: .semibold))
                .tracking(0.2)
            Spacer()
            Picker("", selection: $model.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 110)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.6)
            HStack(spacing: 4) {
                Text(model.t(.licenseNoSubscriptionPrefix))
                    .foregroundStyle(.secondary)
                Link(model.t(.licenseGetItHere), destination: URL(string: "https://markzzy.tech")!)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .padding(.horizontal, -28) // extend divider to window edges
    }

    private var headerTitle: String {
        step == .welcome ? model.t(.licenseWelcomeBack) : model.t(.licenseTitle)
    }

    private var headerSubtitle: String {
        step == .welcome ? model.t(.licenseWelcomeBackSubtitle) : model.t(.licenseSubtitle)
    }

    // MARK: - Welcome step

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(license.pendingEmail)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Button(action: runSendCode) {
                Text(isBusy ? model.t(.licenseSending) : model.t(.licenseSendSignInLink))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)

            HStack {
                Spacer()
                Button(model.t(.licenseUseDifferentEmail)) {
                    license.forgetEmail()
                    email = ""
                    step = .email
                    license.lastError = nil
                }
                .buttonStyle(.link)
                .font(.footnote)
                .disabled(isBusy)
            }
        }
    }

    // MARK: - Email step

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t(.licenseEmail))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .disableAutocorrection(true)
                    .focused($emailFocused)
                    .onSubmit(runSendCode)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        emailFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12),
                        lineWidth: emailFocused ? 1.5 : 1
                    )
            )

            // "Did you mean…?" — fires when the typed domain matches
            // a known typo (gmial→gmail, hotmal→hotmail, etc.). Critical
            // because the backend silently swallows wrong emails (no
            // enumeration), so without this the user would never know
            // why their magic link never arrives.
            if let suggestion = LicenseManager.suggestedCorrection(for: email) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(String(format: model.t(.licenseDidYouMean), suggestion))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(model.t(.licenseUseThis)) {
                        email = suggestion
                    }
                    .buttonStyle(.link)
                    .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }

            Button(action: runSendCode) {
                Text(isBusy ? model.t(.licenseSending) : model.t(.licenseSendCode))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy || !isValidEmail(email))
            .padding(.top, 4)
        }
    }

    private func isValidEmail(_ s: String) -> Bool {
        LicenseManager.isValidEmail(LicenseManager.normalize(s))
    }

    // MARK: - Sent step

    private var sentStep: some View {
        VStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.tint)
            }
            .padding(.top, 2)

            VStack(spacing: 4) {
                Text(String(format: model.t(.licenseLinkSent), license.pendingEmail))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.t(.licenseLinkOpenFromMac))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                // Honest fallback: backend silently swallows non-customer
                // emails (privacy: no enumeration), so users with the
                // wrong email or no subscription will never get the
                // link. Tell them what to do without revealing why.
                Text(model.t(.licenseNoEmailArrivedHint))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            HStack {
                Button(model.t(.licenseResendCode)) { Task { await resend() } }
                    .buttonStyle(.link)
                    .disabled(isBusy)
                Spacer()
                Button(model.t(.licenseWrongEmail)) {
                    step = .email
                    license.lastError = nil
                }
                .buttonStyle(.link)
                .disabled(isBusy)
            }
            .font(.footnote)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    private func runSendCode() {
        Task { @MainActor in
            isBusy = true
            defer { isBusy = false }
            let ok = await license.sendCode(email: email)
            if ok { step = .sent }
        }
    }

    private func resend() async {
        isBusy = true
        defer { isBusy = false }
        _ = await license.sendCode(email: license.pendingEmail.isEmpty ? email : license.pendingEmail)
    }
}
