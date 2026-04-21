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

    /// Production endpoint. For dev testing point this at your local Next.js
    /// server via `#if DEBUG` or set an env var before launch.
    #if DEBUG
    private let apiBase: URL = URL(string: ProcessInfo.processInfo.environment["MARKZZY_API_BASE"] ?? "https://markzzy.tech")!
    #else
    private let apiBase: URL = URL(string: "https://markzzy.tech")!
    #endif

    private let session = URLSession(configuration: .ephemeral)
    private enum KC {
        static let token = "licenseToken"
        static let email = "licenseEmail"
    }

    public init() {
        refreshStatus()
    }

    // MARK: - Public state transitions

    public func refreshStatus() {
        guard let token = Keychain.get(KC.token),
              let claims = Self.decodeClaims(from: token)
        else {
            status = .unactivated
            return
        }
        if claims.expiresAt <= Date() {
            status = .expired
            return
        }
        status = .activated(plan: claims.plan, expiresAt: claims.expiresAt)
    }

    public func signOut() {
        Keychain.remove(KC.token)
        Keychain.remove(KC.email)
        pendingEmail = ""
        lastError = nil
        status = .unactivated
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
            let _ = try await postJSON(path: "/api/license/send-code", body: ["email": normalized])
            pendingEmail = normalized
            Keychain.set(normalized, for: KC.email)
            return true
        } catch {
            lastError = Self.errorMessage(error)
            return false
        }
    }

    public func verify(email: String, code: String) async -> Bool {
        lastError = nil
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            lastError = "Code must be 6 digits"
            return false
        }
        do {
            struct Resp: Decodable { let token: String; let plan: String }
            let resp: Resp = try await postJSON(
                path: "/api/license/verify",
                body: ["email": normalized, "code": digits]
            )
            Keychain.set(resp.token, for: KC.token)
            Keychain.set(normalized, for: KC.email)
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

    @discardableResult
    private func postJSON(path: String, body: [String: String]) async throws -> EmptyResponse {
        try await postJSON(path: path, body: body)
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
