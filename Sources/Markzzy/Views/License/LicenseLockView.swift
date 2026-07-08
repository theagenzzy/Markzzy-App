import SwiftUI

/// Full-screen lock shown when the user's access ended (trial expired
/// without upgrade, monthly canceled and past period_end, payment failed
/// repeatedly). The recording UI is hidden behind this until they
/// reactivate.
///
/// Always offers two paths: upgrade (new subscription) and "I already
/// have one" (re-activate with email — the existing magic-link flow).
struct LicenseLockView: View {
    @ObservedObject var license: LicenseManager
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: lockIcon)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                Button {
                    license.openUpgrade()
                } label: {
                    Label(model.t(.lockUpgradeNow), systemImage: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: 280)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(model.t(.lockHaveSubscription)) {
                    // Re-trigger the activation flow without losing the existing
                    // (now-invalid) Keychain state.
                    license.signOut()
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .foregroundStyle(.blue)
            }

            Spacer()

            Text(model.t(.lockSettingsSaved))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// Icon + text adapt to whether this is a true expiry, a cancellation
    /// past-period-end, or repeated payment failure. Each case warrants a
    /// slightly different message even though the UI shape is the same.
    private var lockIcon: String {
        switch license.status {
        case .expired: return "hourglass"
        case .unactivated: return "person.crop.circle.badge.exclamationmark"
        default:
            if license.subStatus == .canceled { return "calendar.badge.minus" }
            return "lock.fill"
        }
    }

    private var title: String {
        switch license.status {
        case .expired:
            return license.isTrialing ? model.t(.lockTrialEnded) : model.t(.lockSubExpired)
        case .unactivated:
            return model.t(.lockSignInToContinue)
        default:
            if license.subStatus == .canceled { return model.t(.lockSubEnded) }
            return model.t(.lockAccessLocked)
        }
    }

    private var subtitle: String {
        switch license.status {
        case .expired where license.isTrialing:
            return model.t(.lockSubtitleTrialExpired)
        case .expired:
            return model.t(.lockSubtitleReactivate)
        case .unactivated:
            return model.t(.lockSubtitleSignIn)
        default:
            if license.subStatus == .canceled {
                return model.t(.lockSubtitleCanceled)
            }
            return model.t(.lockSubtitleCantVerify)
        }
    }
}
