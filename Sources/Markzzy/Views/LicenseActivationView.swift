import SwiftUI

struct LicenseActivationView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var license: LicenseManager

    @State private var step: Step = .email
    @State private var email: String = ""
    @State private var code: String = ""
    @State private var isBusy: Bool = false

    private enum Step { case email, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Markzzy")
                .font(.system(size: 22, weight: .bold))

            Text(model.t(.licenseTitle))
                .font(.title2.bold())
            Text(model.t(.licenseSubtitle))
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if license.status == .expired {
                Label(model.t(.licenseExpired), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            switch step {
            case .email: emailStep
            case .code:  codeStep
            }

            if let err = license.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Spacer(minLength: 0)

            Text(model.t(.licenseNoSubscription))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 440, height: 380)
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t(.licenseEmail))
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onSubmit(runSendCode)
            Button(action: runSendCode) {
                Text(isBusy ? model.t(.licenseSending) : model.t(.licenseSendCode))
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || email.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: model.t(.licenseCodeSent), license.pendingEmail))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(model.t(.licenseCodePrompt))
                .font(.callout)
            TextField("123456", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .onSubmit(runVerify)
                .onChange(of: code) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue { code = digits }
                    if digits.count > 6 { code = String(digits.prefix(6)) }
                }
            Button(action: runVerify) {
                Text(isBusy ? model.t(.licenseActivating) : model.t(.licenseActivate))
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || code.count != 6)

            HStack {
                Button(model.t(.licenseResendCode)) { Task { await resend() } }
                    .buttonStyle(.link)
                    .disabled(isBusy)
                Spacer()
                Button(model.t(.licenseWrongEmail)) {
                    step = .email
                    code = ""
                    license.lastError = nil
                }
                .buttonStyle(.link)
                .disabled(isBusy)
            }
            .font(.footnote)
        }
    }

    private func runSendCode() {
        Task { @MainActor in
            isBusy = true
            defer { isBusy = false }
            let ok = await license.sendCode(email: email)
            if ok { step = .code }
        }
    }

    private func runVerify() {
        Task { @MainActor in
            isBusy = true
            defer { isBusy = false }
            _ = await license.verify(email: license.pendingEmail, code: code)
        }
    }

    private func resend() async {
        isBusy = true
        defer { isBusy = false }
        _ = await license.sendCode(email: license.pendingEmail)
    }
}
