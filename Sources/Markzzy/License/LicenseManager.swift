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

    @Published public private(set) var status: Status = .unknown
    @Published public var pendingEmail: String = ""
    @Published public var lastError: String?
    /// Cached email derived from the JWT (NOT from Keychain) so SwiftUI body
    /// getters don't hit Security.framework on every redraw — that path was
    /// triggering Keychain access prompts and adding measurable latency.
    @Published public private(set) var activatedEmail: String?

    /// Default to production. For local dev, set MARKZZY_API_BASE in the app's
    /// LSEnvironment (handled by install-to-desktop.sh when the env var is set).
    private let apiBase: URL = URL(
        string: ProcessInfo.processInfo.environment["MARKZZY_API_BASE"] ?? "https://markzzy.tech"
    )!

    private let session = URLSession(configuration: .ephemeral)
    private enum KC {
        static let token = "licenseToken"
        static let email = "licenseEmail"
    }

    private var heartbeatTask: Task<Void, Never>?

    public init() {
        if let saved = Keychain.get(KC.email) {
            pendingEmail = saved
        }
        refreshStatus()
        startHeartbeat()
    }

    deinit {
        heartbeatTask?.cancel()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            // First check happens shortly after launch; then every 6h.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.refreshFromServer()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                await self?.refreshFromServer()
            }
        }
    }

    /// Calls /api/license/refresh to confirm the device is still authorized
    /// and the subscription is still active. On 401 we sign out — that covers
    /// dashboard revocation, expired JWT, and canceled subscription.
    public func refreshFromServer() async {
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
            struct Resp: Decodable { let token: String; let plan: String; let email: String }
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            Keychain.set(resp.token, for: KC.token)
            Keychain.set(resp.email, for: KC.email)
            pendingEmail = resp.email
            refreshStatus()
        } catch {
            // Network blip — keep current state, try again next tick.
        }
    }

    // MARK: - Public state transitions

    public func refreshStatus() {
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
    }

    /// Local-only sign out (used internally on 401 from refresh).
    /// Keeps the email in Keychain so the next sign-in is one-click; only the
    /// JWT token is cleared. Use `forgetEmail()` to wipe both.
    public func signOut() {
        Keychain.remove(KC.token)
        lastError = nil
        status = .unactivated
        activatedEmail = nil
    }

    /// Wipes the remembered email (used by "Use a different email" link).
    public func forgetEmail() {
        Keychain.remove(KC.email)
        pendingEmail = ""
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
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@") else {
            lastError = "Invalid email"
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
        return (error as NSError).localizedDescription
    }

    private static func humanize(serverCode: String) -> String {
        switch serverCode {
        case "invalid_code":   return "That code is not valid."
        case "code_used":      return "This code was already used."
        case "code_expired":   return "Code expired. Request a new one."
        case "email_mismatch": return "Email doesn't match the account."
        case "no_subscription": return "No active subscription found."
        case "invalid_input":  return "Check the email and code."
        case "invalid_link":   return "This activation link is not valid."
        case "link_used":      return "This activation link was already used."
        case "link_expired":   return "Activation link expired. Request a new one."
        case "device_limit":   return "Another Mac is already activated on this account. Sign it out at markzzy.tech, then try again."
        case "device_revoked": return "This Mac was signed out from the dashboard."
        case "invalid_device": return "Couldn't identify this Mac."
        default:               return "Error: \(serverCode)"
        }
    }

    // MARK: - JWT payload decoding (no signature verification)

    struct Claims {
        let plan: String
        let expiresAt: Date
        let email: String
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
        return Claims(plan: plan, expiresAt: Date(timeIntervalSince1970: exp), email: email)
    }

    private static func base64urlDecode(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}
