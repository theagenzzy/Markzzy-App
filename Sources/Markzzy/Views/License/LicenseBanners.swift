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
        // Two display states:
        //   - Server has answered (trialDaysRemaining != nil): show the count
        //     with urgency tint that drifts green → orange → red.
        //   - Server hasn't answered yet (heartbeat in flight or unreachable):
        //     show a degraded "Trial active" banner without a number. Beats
        //     hiding the banner entirely, which used to leave the user with
        //     no upgrade affordance until the network landed.
        if !isDismissedToday, license.isTrialing {
            let days = license.trialDaysRemaining
            let bg = tint(forDays: days)
            HStack(spacing: 10) {
                Image(systemName: (days ?? 99) <= 1 ? "exclamationmark.circle.fill" : "bolt.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(label(forDays: days))
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Button(L10n.t(.trialBannerUpgrade)) { license.openUpgrade() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.white.opacity(0.95))
                    .foregroundStyle(bg)
                Button {
                    dismissedDay = todayKey
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.t(.dismissForToday))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(bg)
            .foregroundStyle(.white)
        }
    }

    private func label(forDays days: Int?) -> String {
        guard let d = days else { return L10n.t(.trialActiveUpgradeAnytime) }
        switch d {
        case 0: return L10n.t(.trialEndsTodayUpgrade)
        case 1: return L10n.t(.trialEndsTomorrowUpgrade)
        default: return String(format: L10n.t(.trialDaysLeftInTrial), d)
        }
    }

    private func tint(forDays days: Int?) -> Color {
        guard let d = days else { return .green }   // unknown = optimistic green
        switch d {
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
                Text(L10n.t(.paymentIssueBanner))
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Button(L10n.t(.licenseUpdatePaymentButton) + " →") { license.openUpdatePayment() }
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
                Text(String(format: L10n.t(.licenseSubEndsOnFormat), Self.dateFormatter.string(from: endsAt)))
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Button(L10n.t(.licenseReactivateButton) + " →") { license.openDashboard() }
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
