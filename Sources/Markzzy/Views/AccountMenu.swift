import SwiftUI

struct AccountMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var license: LicenseManager
    @State private var isSigningOut = false
    @State private var showSignOutConfirm = false

    var body: some View {
        Menu {
            if let email = license.activatedEmail, !email.isEmpty {
                Text(email)
            }
            Link(model.t(.licenseManageOnWeb),
                 destination: URL(string: "https://markzzy.tech/dashboard")!)
            Divider()
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Text(isSigningOut ? model.t(.licenseSigningOut) : model.t(.licenseSignOut))
            }
            .disabled(isSigningOut || license.status == .unactivated)
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(license.activatedEmail ?? "")
        .confirmationDialog(
            model.t(.licenseSignOutConfirmTitle),
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button(model.t(.licenseSignOutConfirm), role: .destructive) {
                isSigningOut = true
                Task { @MainActor in
                    await license.signOutFromServer()
                    isSigningOut = false
                }
            }
            Button(model.t(.cancelAction), role: .cancel) {}
        } message: {
            Text(model.t(.licenseSignOutConfirmBody))
        }
    }
}
