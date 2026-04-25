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
                    Label("Upgrade now", systemImage: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: 280)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("I already have a subscription") {
                    // Re-trigger the activation flow without losing the existing
                    // (now-invalid) Keychain state.
                    license.signOut()
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .foregroundStyle(.blue)
            }

            Spacer()

            Text("All your settings are saved. They'll be there when you come back.")
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
            return license.isTrialing ? "Your trial has ended" : "Your subscription expired"
        case .unactivated:
            return "Sign in to continue"
        default:
            if license.subStatus == .canceled { return "Your subscription ended" }
            return "Access locked"
        }
    }

    private var subtitle: String {
        switch license.status {
        case .expired where license.isTrialing:
            return "Upgrade to Markzzy Monthly or Lifetime to keep recording. All your face cam and layout settings are preserved."
        case .expired:
            return "Reactivate your subscription to keep recording."
        case .unactivated:
            return "Sign in with the email you used to subscribe — we'll email you a one-click activation link."
        default:
            if license.subStatus == .canceled {
                return "Your subscription was canceled. Reactivate any time to pick up where you left off."
            }
            return "We can't verify your access. Try signing in again or contact support."
        }
    }
}
