import Foundation
import SwiftUI

@MainActor
public final class LicenseManager: ObservableObject {
    public enum Status: Equatable {
        case unknown
        case activated(plan: String, expiresAt: Date)
        case unactivated
        case expired
    }

    /// Server-side subscription status — distinct from the JWT-derived `status`.
    /// `status` flips to `.expired` only when the JWT exp passes; this field
    /// flips immediately based on the latest /refresh response, so the UI
    /// can show "past_due" / "cancel_at_period_end" affordances even while
    /// the JWT is still technically valid.
    public enum SubStatus: String, Equatable {
        case trialing, active, pastDue = "past_due", canceled, unknown
    }

    @Published public private(set) var status: Status = .unknown
    @Published public var pendingEmail: String = ""
    @Published public var lastError: String?
    /// Cached email derived from the JWT (NOT from Keychain) so SwiftUI body
    /// getters don't hit Security.framework on every redraw — that path was
    /// triggering Keychain access prompts and adding measurable latency.
    @Published public private(set) var activatedEmail: String? {
        didSet { Telemetry.currentEmail = activatedEmail }   // attribute telemetry to the user
    }

    // MARK: - Server-side subscription state (refreshed on every heartbeat)

    @Published public private(set) var subStatus: SubStatus = .unknown
    /// When the current period ends. For `trial` this is the trial expiration;
    /// for `monthly` it's the next billing date; for `lifetime` it's nil.
    @Published public private(set) var currentPeriodEnd: Date?
    /// True when the user clicked Cancel mid-period. They still have access
    /// until `currentPeriodEnd`, but UI shows "Subscription ends X · Reactivate".
    @Published public private(set) var cancelAtPeriodEnd: Bool = false
    /// Set when the most recent payment attempt failed. Drives the
    /// "Payment issue · Update card" banner.
    @Published public private(set) var paymentFailedAt: Date?
    @Published public private(set) var paymentFailedCount: Int = 0

    /// Default to production. For local dev, override with either:
    ///   1. Shell env var (baked into LSEnvironment by install-to-desktop.sh
    ///      when MARKZZY_API_BASE is exported at install time), OR
    ///   2. `defaults write dev.markzzy.app MARKZZY_API_BASE http://localhost:3000`
    ///      — survives rebuilds, no need to re-export before each install.
    /// Resolution order: env > UserDefaults > production. UserDefaults wins
    /// for dev convenience: set it once on a dev machine and every rebuild
    /// of the app keeps pointing at localhost.
    private let apiBase: URL = {
        let prod = URL(string: "https://markzzy.tech")!
        // SECURITY: the env/UserDefaults override is DEV-ONLY (bundle id prefix
        // `dev.`). A production build (`tech.markzzy.Markzzy`) ALWAYS uses the
        // hardcoded production origin, so it can never be redirected to a rogue
        // server via `defaults write` (which, combined with the unsigned JWT,
        // would be a license bypass).
        guard (Bundle.main.bundleIdentifier ?? "").hasPrefix("dev.") else { return prod }
        if let env = ProcessInfo.processInfo.environment["MARKZZY_API_BASE"],
           let url = URL(string: env) { return url }
        if let pref = UserDefaults.standard.string(forKey: "MARKZZY_API_BASE"),
           let url = URL(string: pref) { return url }
        return prod
    }()

    /// Same origin as `apiBase` — use for links to the web dashboard,
    /// changelog, marketing pages, etc. Deriving from `apiBase` means a
    /// dev build (`MARKZZY_API_BASE=http://localhost:3000`) opens the
    /// LOCAL dashboard from "Upgrade", "Manage on web", etc., instead
    /// of jumping to production every time you click a button.
    public var webBase: URL { apiBase }

    /// URLSession with short, explicit timeouts. Default URLSession
    /// timeouts are 60 s — way too long for the user staring at a
    /// "Sending…" spinner. 15 s is more than enough for a healthy
    /// server; if we don't get a response by then it's almost
    /// certainly a server outage and the user needs a clear error,
    /// not a frozen spinner.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()
    private enum KC {
        static let token = "licenseToken"
        static let email = "licenseEmail"
    }
    /// UserDefaults key for the cached `currentPeriodEnd`. We persist this
    /// across launches so the trial countdown shows a real number from the
    /// first frame even when the device is offline (or the heartbeat is
    /// still in flight). Without the cache the UI flashes "Trial active"
    /// without a count for the seconds it takes the network to respond.
    private static let cachedPeriodEndKey = "MARKZZY_CACHED_PERIOD_END"

    private var heartbeatTask: Task<Void, Never>?

    // MARK: - Test-only state injectors
    //
    // Mark internal so @testable import can reach them; production code
    // never touches these (would be a sign of misusing the state machine).

    #if DEBUG
    func _test_setSubStatus(_ s: SubStatus) { subStatus = s }
    func _test_setCurrentPeriodEnd(_ d: Date?) { currentPeriodEnd = d }
    func _test_setCancelAtPeriodEnd(_ b: Bool) { cancelAtPeriodEnd = b }
    func _test_setPaymentFailedAt(_ d: Date?) { paymentFailedAt = d }
    func _test_setPaymentFailedCount(_ n: Int) { paymentFailedCount = n }
    #endif

    // MARK: - Computed state — drives all the trial/banner/lock UIs

    /// Currently in the 14-day free trial period.
    /// Reads from server-hydrated `subStatus` first; falls back to the JWT
    /// plan field so the trial UI shows IMMEDIATELY at launch (before the
    /// first heartbeat refresh, which lands ~5 s later). Without this
    /// fallback the user briefly sees the wrong UI on every launch.
    public var isTrialing: Bool {
        if subStatus == .trialing { return true }
        if subStatus == .unknown,
           case .activated(let plan, _) = status,
           plan == "trial" {
            return true
        }
        return false
    }

    /// Lifetime plan — never expires, no banners, no upgrade pressure.
    public var isLifetime: Bool {
        if case .activated(let plan, _) = status { return plan == "lifetime" }
        return false
    }

    /// Monthly subscription, fully paid up.
    public var isMonthlyActive: Bool {
        if case .activated(let plan, _) = status { return plan == "monthly" && subStatus != .pastDue }
        return false
    }

    /// Days remaining in the trial. Returns nil if not on a trial.
    /// Floor-rounded so "0 days" means "ends sometime today".
    /// When the server hasn't hydrated `currentPeriodEnd` yet, falls back
    /// to the JWT exp claim — for trials, those line up (trial JWT TTL =
    /// trial period end).
    /// Days left in the trial. Reads ONLY `currentPeriodEnd` (server-set);
    /// returns nil until the first heartbeat lands. We deliberately don't
    /// fall back to the JWT `exp` — the JWT lives 90 d from issuance, which
    /// has nothing to do with the 14-d trial window. Falling back caused
    /// the hero to flash "6 days left" at launch (JWT had 6 d of life)
    /// before snapping to the real "10 days" once the server response came
    /// back. Better to show "Free trial" with no count than a wrong count.
    public var trialDaysRemaining: Int? {
        guard isTrialing, let end = currentPeriodEnd else { return nil }
        let seconds = end.timeIntervalSinceNow
        if seconds <= 0 { return 0 }
        return max(0, Int(seconds / 86_400))
    }

    /// Charge date for the trial countdown. Same rule as above: only
    /// trust the server-set `currentPeriodEnd`, never the JWT exp.
    public var trialChargeDate: Date? {
        guard isTrialing else { return nil }
        return currentPeriodEnd
    }

    /// Most recent payment attempt failed and PayPal is still retrying.
    /// Show "Update payment method" affordance.
    public var paymentPastDue: Bool { subStatus == .pastDue }

    /// User canceled but the period hasn't ended yet — they still have full
    /// access. Show "Subscription ends X · Reactivate" affordance.
    public var willEndAt: Date? {
        guard cancelAtPeriodEnd, let end = currentPeriodEnd else { return nil }
        return end
    }

    /// True when access is permanently locked (trial expired, sub canceled
    /// past period_end, payment failed too many times). Triggers full-screen
    /// LicenseLockView.
    public var isLocked: Bool {
        switch status {
        case .expired, .unactivated:
            return true
        case .activated:
            return subStatus == .canceled  // canceled at period end
        case .unknown:
            return false  // optimistic during first launch
        }
    }

    public init() {
        if let saved = Keychain.get(KC.email) {
            pendingEmail = saved
        }
        // Restore the last-known `currentPeriodEnd` from UserDefaults so the
        // trial banner and License hero have a number to show on the very
        // first frame, even if the heartbeat is offline / slow / not yet
        // started. The next successful heartbeat overwrites this.
        let cached = UserDefaults.standard.double(forKey: Self.cachedPeriodEndKey)
        if cached > 0 {
            currentPeriodEnd = Date(timeIntervalSince1970: cached)
        }
        // Local JWT decode + Keychain read — fast, must run sync so the
        // app shell knows whether to render the activation flow vs the
        // main UI on the very first frame.
        refreshStatus()
        // Heartbeat (network) intentionally NOT started here. MarkzzyApp's
        // `.task` calls `start()` after the first frame so the network
        // call doesn't block window presentation.
    }

    deinit {
        heartbeatTask?.cancel()
    }

    /// Kicks off the periodic server refresh. Safe to call multiple times
    /// — additional calls are no-ops because the existing task is reused.
    public func start() {
        guard heartbeatTask == nil else { return }
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            // First refresh fires immediately (no delay) so the trial
            // countdown / past-due / canceled banners hydrate in
            // milliseconds, not 5 seconds. Without this, the user sees
            // a stale UI flash for a full second after launch.
            await self?.refreshFromServer()
            while !Task.isCancelled {
                let interval = await self?.heartbeatInterval ?? 21_600  // 6h fallback
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                await self?.refreshFromServer()
            }
        }
    }

    /// Adaptive heartbeat: more frequent when state is "interesting" (trial
    /// ending, payment past due) so the UI reflects upgrades / payment
    /// fixes within seconds. Backs off to once-per-6h when everything is
    /// steady, to avoid burning battery + server load.
    private var heartbeatInterval: TimeInterval {
        // Trial day-of-expiration → check often to catch the upgrade fast.
        if let days = trialDaysRemaining, days <= 1 {
            return 300       // 5 min
        }
        // Payment failing → check often to catch the user's fix.
        if paymentPastDue {
            return 300       // 5 min
        }
        // Trial mid-period → moderate.
        if isTrialing {
            return 1800      // 30 min
        }
        // Lifetime → never expires, lowest priority.
        if isLifetime {
            return 86_400    // 24 h
        }
        // Monthly active or unknown → standard.
        return 21_600        // 6 h
    }

    /// Calls /api/license/refresh to confirm the device is still authorized
    /// and the subscription is still active. On 401 we sign out — that covers
    /// dashboard revocation, expired JWT, and canceled subscription.
    public func refreshFromServer() async {
        // Dev builds keep the local fake trial — never let the server
        // (which sees the real expired token) override it.
        if Self.isDevBuild {
            await MainActor.run { refreshStatus() }
            return
        }
        guard let token = Keychain.get(KC.token) else { return }
        var req = URLRequest(url: apiBase.appendingPathComponent("/api/license/refresh"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 || http.statusCode == 403 {
                signOut()
                lastError = (try? JSONDecoder().decode(ErrorBody.self, from: data))
                    .map { Self.humanize(serverCode: $0.error) }
                return
            }
            guard (200..<300).contains(http.statusCode) else { return }
            struct Resp: Decodable {
                let token: String
                let plan: String
                let email: String
                // Enriched fields (added in Sprint 2 backend). All optional
                // so older server responses don't break decoding.
                let status: String?
                let currentPeriodEnd: String?
                let cancelAtPeriodEnd: Bool?
                let canceledAt: String?
                let paymentFailedAt: String?
                let paymentFailedCount: Int?
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let resp = try decoder.decode(Resp.self, from: data)
            Keychain.set(resp.token, for: KC.token)
            Keychain.set(resp.email, for: KC.email)
            pendingEmail = resp.email

            // Hydrate the published state machine fields.
            subStatus = SubStatus(rawValue: resp.status ?? "") ?? .unknown
            currentPeriodEnd = resp.currentPeriodEnd.flatMap { Self.parseISO8601($0) }
            cancelAtPeriodEnd = resp.cancelAtPeriodEnd ?? false
            paymentFailedAt = resp.paymentFailedAt.flatMap { Self.parseISO8601($0) }
            paymentFailedCount = resp.paymentFailedCount ?? 0

            // Persist `currentPeriodEnd` so the next launch can show the
            // trial countdown immediately, even if offline. Clearing on
            // nil keeps the cache truthful when the user moves to a plan
            // without a period (e.g. lifetime).
            if let end = currentPeriodEnd {
                UserDefaults.standard.set(end.timeIntervalSince1970,
                                          forKey: Self.cachedPeriodEndKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.cachedPeriodEndKey)
            }

            refreshStatus()
        } catch {
            // Network blip — keep current state, try again next tick.
        }
    }

    /// Robust ISO8601 parser that accepts both with and without fractional
    /// seconds. Postgres usually returns "2026-05-05T10:00:00+00:00",
    /// but some serializers add ".123".
    private static func parseISO8601(_ s: String) -> Date? {
        let formatters: [ISO8601DateFormatter] = [
            { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }(),
            { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }(),
        ]
        for f in formatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - Public state transitions

    /// Local dev builds (`dev.markzzy.app`) bypass trial expiry so the
    /// developer can keep testing without re-issuing tokens. Production
    /// (`tech.markzzy.Markzzy`) is unaffected — real users still hit the
    /// server-authoritative expiry. Gated on bundle id so it can never
    /// ship in a notarized build.
    private static var isDevBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasPrefix("dev.")
    }

    public func refreshStatus() {
        // Dev builds NEVER touch the keychain — that's what triggers the
        // "Markzzy wants to access key dev.markzzy.app" password prompt
        // on every rebuild (the keychain ACL is tied to the binary
        // signature; even with a stable dev cert the prompt can recur).
        // The dev fake-trial doesn't need a token, so skip the keychain
        // read entirely and the prompt never appears.
        if Self.isDevBuild {
            status = .activated(plan: "trial",
                                expiresAt: Date().addingTimeInterval(365 * 86_400))
            activatedEmail = "dev@markzzy.local"
            currentPeriodEnd = Date().addingTimeInterval(365 * 86_400)
            return
        }
        guard let token = Keychain.get(KC.token),
              let claims = Self.decodeClaims(from: token)
        else {
            status = .unactivated
            activatedEmail = nil
            return
        }
        if claims.expiresAt <= Date() {
            status = .expired
            activatedEmail = nil
            return
        }
        status = .activated(plan: claims.plan, expiresAt: claims.expiresAt)
        activatedEmail = claims.email.isEmpty ? nil : claims.email
        // Seed currentPeriodEnd from the JWT only when the heartbeat
        // hasn't filled it yet — backend is always more authoritative
        // (it sees mid-period upgrades/cancels), but this gets the trial
        // countdown showing a real number from the very first frame.
        if currentPeriodEnd == nil, let je = claims.periodEnd {
            currentPeriodEnd = je
        }
        // If the JWT is from an older schema, fire an immediate refresh
        // off-thread instead of waiting for the periodic heartbeat
        // (which can be 30 min for trial mid-period or 6 h for steady
        // state). The user opens an app that just got an update — they
        // expect to see the new behavior right away, not in 6 hours.
        if claims.schemaVersion < Self.currentJWTSchema {
            Task { await refreshFromServer() }
        }
    }

    /// Local-only sign out (used internally on 401 from refresh).
    /// Keeps the email in Keychain so the next sign-in is one-click; only the
    /// JWT token is cleared. Use `forgetEmail()` to wipe both.
    public func signOut() {
        Keychain.remove(KC.token)
        lastError = nil
        status = .unactivated
        activatedEmail = nil
        currentPeriodEnd = nil
        // Clear cached state too — leaving it would cause the next user to
        // sign in and briefly see the previous user's trial countdown.
        UserDefaults.standard.removeObject(forKey: Self.cachedPeriodEndKey)
    }

    /// Wipes the remembered email (used by "Use a different email" link).
    public func forgetEmail() {
        Keychain.remove(KC.email)
        pendingEmail = ""
    }

    // MARK: - Deep links into the web for upgrade / manage / cancel

    /// Helper: build a `webBase`-rooted URL with optional path + query
    /// items. Centralizes the dev/prod URL switch so every CTA in the
    /// app respects MARKZZY_API_BASE without each one duplicating the
    /// URLComponents boilerplate.
    private func webURL(path: String, query: [URLQueryItem]? = nil) -> URL? {
        var c = URLComponents(url: webBase.appendingPathComponent(path),
                              resolvingAgainstBaseURL: false)
        c?.queryItems = query
        return c?.url
    }

    /// Pre-fills the email query param when we know it. Lets the web
    /// skip re-auth if the user is already logged in.
    private var emailQueryItem: URLQueryItem {
        URLQueryItem(name: "email", value: activatedEmail ?? pendingEmail)
    }

    /// Opens the dashboard in the user's browser.
    public func openDashboard() {
        if let url = webURL(path: "dashboard", query: [emailQueryItem]) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Drives the "Upgrade" CTAs in trial banners and lock screens.
    /// Lands on the dashboard with action=upgrade so the web can
    /// auto-open the Monthly/Lifetime upgrade modal. Pass `plan` to
    /// pre-select Monthly or Lifetime in the modal — used by the hero's
    /// segmented picker so the user lands directly on the right checkout
    /// instead of choosing again on the web.
    public func openUpgrade(plan: String? = nil) {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "action", value: "upgrade"),
            emailQueryItem,
        ]
        if let plan = plan {
            items.append(URLQueryItem(name: "plan", value: plan))
        }
        if let url = webURL(path: "dashboard", query: items) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Past-due banner CTA. Goes to the dashboard's billing page where
    /// the user can update their payment method.
    public func openUpdatePayment() {
        if let url = webURL(path: "dashboard/billing", query: [emailQueryItem]) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Cancel-subscription CTA from Settings. Opens the dashboard with
    /// `?action=cancel` so the web auto-opens the confirm dialog (also
    /// offers to switch to Lifetime — classic save-the-deal). We do this
    /// via web instead of a JWT-authed API call so cancel auth flows
    /// stay behind session cookies — smaller security surface.
    public func openCancel() {
        if let url = webURL(path: "dashboard", query: [
            URLQueryItem(name: "action", value: "cancel"),
            emailQueryItem,
        ]) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the marketing site root.
    public func openWebsite() {
        if let url = webURL(path: "") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the changelog page.
    public func openChangelog() {
        if let url = webURL(path: "changelog") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True when this Mac was previously activated (we have a remembered
    /// email even after sign-out). Drives the "Welcome back" UI.
    public var hasRememberedEmail: Bool {
        !pendingEmail.isEmpty
    }

    /// User-initiated sign out — also revokes the device on the server so the
    /// 1-device cap frees up immediately for activating on a different Mac.
    public func signOutFromServer() async {
        if let token = Keychain.get(KC.token) {
            var req = URLRequest(url: apiBase.appendingPathComponent("/api/license/devices/current"))
            req.httpMethod = "DELETE"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: req)
        }
        signOut()
    }

    // MARK: - Network

    public func sendCode(email: String) async -> Bool {
        lastError = nil
        let normalized = Self.normalize(email)
        // Catch obvious malformed input BEFORE round-tripping. The
        // backend always returns ok:true (privacy — see /send-code) so
        // a typo there means the user just never gets a magic link
        // and never knows why. Validate hard up front.
        if let validationError = Self.validationError(for: normalized) {
            lastError = validationError
            return false
        }
        do {
            let _: EmptyResponse = try await postJSON(path: "/api/license/send-code", body: ["email": normalized])
            pendingEmail = normalized
            Keychain.set(normalized, for: KC.email)
            return true
        } catch {
            lastError = Self.errorMessage(error)
            return false
        }
    }

    // MARK: - Email validation + typo correction

    /// Strips whitespace and lowercases. Always use this before sending
    /// the email to the server or storing it locally.
    public nonisolated static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Reasonable email regex — strict enough to catch obvious typos
    /// like "a@b" or "user@domain" (no TLD), permissive enough not to
    /// reject legitimate addresses with `+tag`, dots in local part,
    /// or new TLDs. Not RFC-compliant (those regexes are pages long
    /// and reject the same emails that work in real life).
    private nonisolated static let emailRegex = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#

    public nonisolated static func isValidEmail(_ s: String) -> Bool {
        s.range(of: emailRegex, options: .regularExpression) != nil
    }

    /// Returns a user-facing error message for invalid input, or nil if
    /// the email is well-formed. Differentiated by what's wrong so the
    /// user knows what to fix.
    public nonisolated static func validationError(for email: String) -> String? {
        if email.isEmpty {
            return "Please enter your email."
        }
        if !email.contains("@") {
            return "An email needs an @ — like you@gmail.com."
        }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        if parts.count != 2 || parts[0].isEmpty {
            return "Add your username before the @."
        }
        if parts[1].isEmpty {
            return "Add the domain after the @ — like gmail.com."
        }
        if !parts[1].contains(".") {
            return "Email looks incomplete — make sure it ends with .com or similar."
        }
        if !isValidEmail(email) {
            return "That doesn't look like a valid email."
        }
        return nil
    }

    /// Common typos in popular email domains. Used for "Did you mean?"
    /// suggestions in the UI. Keys must already be lowercased.
    /// Add new ones as we see them in support tickets.
    public nonisolated static let domainTypos: [String: String] = [
        // Gmail
        "gmial.com": "gmail.com",
        "gmai.com": "gmail.com",
        "gmal.com": "gmail.com",
        "gmail.con": "gmail.com",
        "gmail.co": "gmail.com",
        "gmaill.com": "gmail.com",
        "gnail.com": "gmail.com",
        "gemail.com": "gmail.com",
        // Hotmail
        "hotmial.com": "hotmail.com",
        "hotmal.com": "hotmail.com",
        "hotmai.com": "hotmail.com",
        "hotmail.con": "hotmail.com",
        "hotmail.co": "hotmail.com",
        "hotnail.com": "hotmail.com",
        // Yahoo
        "yaho.com": "yahoo.com",
        "yahooo.com": "yahoo.com",
        "yahoo.con": "yahoo.com",
        "yahoo.co": "yahoo.com",
        "yhoo.com": "yahoo.com",
        // Outlook
        "outlok.com": "outlook.com",
        "outloo.com": "outlook.com",
        "outlook.con": "outlook.com",
        "outlook.co": "outlook.com",
        "outllok.com": "outlook.com",
        // iCloud
        "iclod.com": "icloud.com",
        "icloud.con": "icloud.com",
        "icloud.co": "icloud.com",
        "iclou.com": "icloud.com",
        "iclould.com": "icloud.com",
    ]

    /// Returns a corrected version of `email` if the domain matches a
    /// known typo, or nil if the email looks fine. Caller decides
    /// whether to auto-correct or just suggest.
    public nonisolated static func suggestedCorrection(for email: String) -> String? {
        let normalized = normalize(email)
        let parts = normalized.split(separator: "@", maxSplits: 1)
        guard parts.count == 2,
              let fix = domainTypos[String(parts[1])]
        else { return nil }
        return "\(parts[0])@\(fix)"
    }

    public func redeem(token: String) async -> Bool {
        lastError = nil
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            lastError = "Invalid activation link"
            return false
        }
        do {
            struct Resp: Decodable { let token: String; let plan: String; let email: String }
            let resp: Resp = try await postJSON(
                path: "/api/license/redeem",
                body: [
                    "token": trimmed,
                    "device_id": DeviceIdentity.id(),
                    "device_name": DeviceIdentity.name(),
                ]
            )
            Keychain.set(resp.token, for: KC.token)
            Keychain.set(resp.email, for: KC.email)
            pendingEmail = resp.email
            refreshStatus()
            return true
        } catch {
            lastError = Self.errorMessage(error)
            return false
        }
    }

    // MARK: - HTTP helper

    private func postJSON<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        var req = URLRequest(url: apiBase.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LicenseError.network("No response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw LicenseError.server(err.error)
            }
            throw LicenseError.server("HTTP \(http.statusCode)")
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct EmptyResponse: Decodable {}
    struct ErrorBody: Decodable { let error: String }

    enum LicenseError: Error {
        case network(String)
        case server(String)
    }

    private static func errorMessage(_ error: Error) -> String {
        if let e = error as? LicenseError {
            switch e {
            case .network(let m): return "Network: \(m)"
            case .server(let m): return Self.humanize(serverCode: m)
            }
        }
        // URLSession timeouts and connection errors land here. Translate
        // them into something the user understands instead of a generic
        // "The request timed out." — most users have no idea what to do
        // with that.
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost:
                return "Couldn't reach the Markzzy server. Check your internet connection — if it's working, the server may be temporarily down. Try again in a moment."
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection. Check your Wi-Fi and try again."
            default:
                break
            }
        }
        return ns.localizedDescription
    }

    private static func humanize(serverCode: String) -> String {
        switch serverCode {
        case "invalid_code":   return "That code is not valid."
        case "code_used":      return "This code was already used."
        case "code_expired":   return "Code expired. Request a new one."
        case "email_mismatch": return "Email doesn't match the account."
        case "no_subscription": return "This email doesn't have an active subscription. Get one at markzzy.tech."
        case "invalid_input":  return "Check the email and code."
        case "invalid_link":   return "This activation link is not valid."
        case "link_used":      return "This activation link was already used."
        case "link_expired":   return "Activation link expired. Request a new one."
        case "device_limit":   return "Another Mac is already activated on this account. Sign it out at markzzy.tech, then try again."
        case "device_revoked": return "This Mac was signed out from the dashboard."
        case "invalid_device": return "Couldn't identify this Mac."
        case "rate_limited", "too_many_requests":
                               return "Too many attempts. Wait a minute and try again."
        case "server_error", "internal_error":
                               return "Server error. We're already on it — try again in a moment."
        default:
            // Don't show raw codes to users. Keep the code in the
            // message but in parentheses for support tickets.
            return "Something unexpected happened (\(serverCode)). If this keeps happening, contact support."
        }
    }

    // MARK: - JWT payload decoding (no signature verification)

    /// Schema version this build of the Mac app expects from the JWT.
    /// MUST equal `JWT_SCHEMA_VERSION` in `markzzy-web/lib/jwt.ts`. When
    /// the backend bumps its version and we ship a Mac update bumping
    /// this constant, any user whose JWT is older than this value gets
    /// an immediate `/api/license/refresh` on next launch instead of
    /// waiting hours for the periodic heartbeat — see `refreshStatus()`.
    public static let currentJWTSchema: Int = 2

    struct Claims {
        let plan: String
        let expiresAt: Date
        let email: String
        /// Trial / billing period end embedded in the JWT by the backend.
        /// Lets the trial countdown render from the first frame, even
        /// before the heartbeat lands. Nil for lifetime users.
        let periodEnd: Date?
        /// Schema version of this JWT. Older than `currentJWTSchema` →
        /// triggers an immediate refresh.
        let schemaVersion: Int
    }

    static func decodeClaims(from token: String) -> Claims? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payloadPart = String(parts[1])
        guard let data = base64urlDecode(payloadPart),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? TimeInterval,
              let plan = obj["plan"] as? String
        else { return nil }
        let email = obj["email"] as? String ?? ""
        let periodEnd = (obj["period_end"] as? String).flatMap { Self.parseISO8601($0) }
        // Default to 1 (the implicit pre-versioning era). A JWT with no
        // `v` claim came from a backend before we added the field, so
        // it's by definition older than anything we'd ship today.
        let schemaVersion = obj["v"] as? Int ?? 1
        return Claims(plan: plan, expiresAt: Date(timeIntervalSince1970: exp),
                      email: email, periodEnd: periodEnd, schemaVersion: schemaVersion)
    }

    private static func base64urlDecode(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
