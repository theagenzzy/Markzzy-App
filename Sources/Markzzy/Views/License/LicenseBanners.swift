import SwiftUI

/// Persistent banner shown at the top of the main window when the user
/// has an active trial. Color shifts urgency: green > yellow > red as
/// the trial winds down so the user can't miss the impending charge.
///
/// Tap → opens upgrade in browser. Dismissable per-day (X button).
struct TrialBanner: View {
    @ObservedObject var license: LicenseManager
    @AppStorage("trialBannerDismissedDay") private var dismissedDay: String = ""

    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var isDismissedToday: Bool { dismissedDay == todayKey }

    var body: some View {
        if let days = license.trialDaysRemaining, !isDismissedToday {
            HStack(spacing: 10) {
                Image(systemName: days <= 1 ? "exclamationmark.circle.fill" : "bolt.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(label(forDays: days))
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Button("Upgrade →") { license.openUpgrade() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.white.opacity(0.95))
                    .foregroundStyle(tint(forDays: days))
                Button {
                    dismissedDay = todayKey
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Dismiss for today")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(tint(forDays: days))
            .foregroundStyle(.white)
        }
    }

    private func label(forDays days: Int) -> String {
        switch days {
        case 0: return "Trial ends today — upgrade to keep recording"
        case 1: return "Trial ends tomorrow — upgrade now"
        default: return "\(days) days left in trial"
        }
    }

    private func tint(forDays days: Int) -> Color {
        switch days {
        case 0: return .red
        case 1...3: return .orange
        default: return .green
        }
    }
}

/// Shown when PayPal payment failed and they're retrying. User has full
/// access during retry window (PayPal does smart retries over 7 days),
/// but we want them to fix their card ASAP.
struct PaymentIssueBanner: View {
    @ObservedObject var license: LicenseManager

    var body: some View {
        if license.paymentPastDue {
            HStack(spacing: 10) {
                Image(systemName: "creditcard.trianglebadge.exclamationmark")
                    .font(.system(size: 14, weight: .semibold))
                Text("Payment issue — update your card to avoid interruption")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Button("Update payment →") { license.openUpdatePayment() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.white)
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.red)
            .foregroundStyle(.white)
        }
    }
}

/// Shown when user clicked "Cancel" mid-period. They keep access until
/// `currentPeriodEnd`, but the banner reminds them and offers an easy
/// "Reactivate" path back.
struct CanceledBanner: View {
    @ObservedObject var license: LicenseManager

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        if let endsAt = license.willEndAt {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                Text("Subscription ends \(Self.dateFormatter.string(from: endsAt))")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Button("Reactivate →") { license.openDashboard() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.white)
                    .foregroundStyle(.indigo)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.indigo)
            .foregroundStyle(.white)
        }
    }
}

/// Composes the three banners. Show order: payment past-due (most
/// urgent) > canceled > trial. Only ONE shows at a time so the UI doesn't
/// stack three bars on top of each other.
struct LicenseBannerStack: View {
    @ObservedObject var license: LicenseManager

    var body: some View {
        Group {
            if license.paymentPastDue {
                PaymentIssueBanner(license: license)
            } else if license.willEndAt != nil {
                CanceledBanner(license: license)
            } else if license.isTrialing {
                TrialBanner(license: license)
            }
        }
    }
}
