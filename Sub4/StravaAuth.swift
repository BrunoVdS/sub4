//
//  StravaAuth.swift
//  Sub4
//
//  Strava OAuth, entirely in-app.
//
//  TRADE-OFF, stated plainly: Strava's token exchange requires the client
//  secret, and anything in an app binary is extractable. For a personal app on
//  your own phone that is an acceptable risk — the secret alone grants nobody
//  access to your data without your token. If this ever leaves your device,
//  move the exchange behind the one.com backend instead. `TokenProvider` is the
//  seam that makes that a swap rather than a rewrite.
//

import Foundation
import AuthenticationServices

// MARK: - Cancellation is not a failure
//
// Every network call in this app runs inside a structured task: `.task {}` on a
// view, or `.refreshable {}`. iOS cancels those routinely and correctly — the
// tab changes, the refresh control retracts, the view is torn down. URLSession
// then throws `URLError.cancelled`, whose localizedDescription is the single
// word "cancelled", and a plain `catch { lastError = error.localizedDescription }`
// writes that into the UI as a Strava error banner.
//
// It is not one. Nothing failed, nothing needs fixing, and the banner sends you
// looking for a problem in Strava that does not exist. A cancelled request is
// simply a request that will be made again next time.
//
// The same applies to the login sheet: dismissing it is a decision, not an
// error, and `ASWebAuthenticationSessionError.canceledLogin` should leave no
// trace either.

extension Error {

    /// True when this error means "the work was called off", not "the work failed".
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let u = self as? URLError, u.code == .cancelled { return true }
        if let a = self as? ASWebAuthenticationSessionError,
           a.code == .canceledLogin { return true }
        // Anything that reached here as a plain NSError rather than a bridged
        // Swift error — the typed casts above miss those.
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

enum StravaConfig {

    // Credentials are entered once in Settings and stored in the iOS Keychain —
    // deliberately NOT hard-coded here.
    //
    // They used to be constants in this file, which had two problems: any patch
    // that shipped StravaAuth.swift silently reverted them to placeholders, and
    // the client secret sat in the git history. Keychain fixes both — the keys
    // survive every future code update and never touch the repository.

    struct Credentials: Codable, Equatable {
        var clientID: String
        var clientSecret: String
    }

    private static let keychainKey = "strava.credentials"

    static var credentials: Credentials? {
        Keychain.load(keychainKey, as: Credentials.self)
    }

    static func save(_ c: Credentials) { Keychain.save(c, key: keychainKey) }

    static var isConfigured: Bool {
        guard let c = credentials else { return false }
        return !c.clientID.trimmingCharacters(in: .whitespaces).isEmpty
            && !c.clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static var clientID: String { credentials?.clientID ?? "" }
    static var clientSecret: String { credentials?.clientSecret ?? "" }

    /// Must match the URL scheme registered in Info.plist.
    static let callbackScheme = "sub4"
    static let redirectURI    = "sub4://localhost"

    /// `profile:read_all` is what unlocks /athlete/zones (HR zones) and gear
    /// distances on /athlete. Adding a scope invalidates the old grant, so
    /// existing users must disconnect and reconnect once.
    static let scope = "activity:read_all,profile:read_all"
}

struct StravaTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: TimeInterval

    var isExpired: Bool { Date().timeIntervalSince1970 >= expiresAt - 120 }
}

@Observable
final class StravaAuth: NSObject {

    static let shared = StravaAuth()

    private(set) var tokens: StravaTokens?
    private(set) var lastError: String?

    var isConnected: Bool { tokens != nil }

    private let keychainKey = "strava.tokens"
    private var session: ASWebAuthenticationSession?

    private override init() {
        super.init()
        tokens = Keychain.load(keychainKey, as: StravaTokens.self)
    }

    // MARK: Connect

    @MainActor
    func connect() async {
        // Patch 178, plan step 0.3.
        //
        // `stravaConnect` is a SEPARATE gate from `stravaSync`, and M8 is the
        // reason: revoking an OAuth token requires still holding it. One switch
        // covering both would force a choice between stopping the reads and
        // keeping the ability to revoke cleanly. Two lets the reads stop today
        // and the revocation happen on its own schedule.
        guard ReleaseGates.isOpen(.stravaConnect) else {
            lastError = GateError(gate: .stravaConnect).errorDescription
            return
        }
        guard StravaConfig.isConfigured else {
            lastError = "Add your Strava API keys below — Client ID and Client "
                      + "Secret from strava.com/settings/api."
            return
        }

        var comps = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        comps.queryItems = [
            .init(name: "client_id",       value: StravaConfig.clientID),
            .init(name: "redirect_uri",    value: StravaConfig.redirectURI),
            .init(name: "response_type",   value: "code"),
            .init(name: "approval_prompt", value: "auto"),
            .init(name: "scope",           value: StravaConfig.scope)
        ]

        guard let url = comps.url else { return }

        let code: String? = await withCheckedContinuation { cont in
            let s = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: StravaConfig.callbackScheme
            ) { callback, error in
                guard let callback,
                      let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                        .queryItems,
                      let code = items.first(where: { $0.name == "code" })?.value
                else {
                    cont.resume(returning: nil)
                    // Dismissing the login sheet is a decision, not a failure.
                    if let error, !error.isCancellation {
                        self.lastError = error.localizedDescription
                    }
                    return
                }
                cont.resume(returning: code)
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            s.start()
        }

        guard let code else { return }
        await exchange(code: code)
    }

    func disconnect() {
        tokens = nil
        Keychain.delete(keychainKey)
    }

    // MARK: Token lifecycle

    private func exchange(code: String) async {
        await post(body: [
            "client_id":     StravaConfig.clientID,
            "client_secret": StravaConfig.clientSecret,
            "code":          code,
            "grant_type":    "authorization_code"
        ])
    }

    /// When the current access token dies. Surfaced in Settings so an auth
    /// problem is diagnosable instead of just showing up as a 401.
    var expiry: Date? {
        tokens.map { Date(timeIntervalSince1970: $0.expiresAt) }
    }

    var isExpired: Bool { tokens?.isExpired ?? true }

    /// Returns a usable access token, refreshing if needed.
    ///
    /// Returns nil rather than handing back a token known to be dead — the old
    /// version returned `tokens?.accessToken` even when the refresh had failed,
    /// which turned an auth problem into a confusing 401 from the API instead.
    func validAccessToken(forceRefresh: Bool = false) async -> String? {
        guard let t = tokens else {
            lastError = "Not connected to Strava."
            return nil
        }
        if !forceRefresh, !t.isExpired { return t.accessToken }
        return await refresh() ? tokens?.accessToken : nil
    }

    /// Exchanges the refresh token. Returns whether it worked.
    @discardableResult
    func refresh() async -> Bool {
        guard let t = tokens else { return false }
        return await post(body: [
            "client_id":     StravaConfig.clientID,
            "client_secret": StravaConfig.clientSecret,
            "refresh_token": t.refreshToken,
            "grant_type":    "refresh_token"
        ])
    }

    /// DELIBERATELY UNGATED, and this is the one exception in the app — patch 178.
    ///
    /// Every other Strava endpoint sits behind a switch. This one carries no
    /// athlete data in either direction: it exchanges a code for a token, or a
    /// refresh token for a fresh one. Gating it would break the thing the gates
    /// exist to make possible, because M8 has to revoke the authorisation
    /// remotely before deleting it locally, and a token that cannot be refreshed
    /// cannot be revoked — it just expires, leaving Sub4 authorised on Strava's
    /// side forever with no way to withdraw.
    ///
    /// Closing `stravaSync` already means no token is fetched in the ordinary
    /// course, because nothing asks for one. This path stays open so that when
    /// the time comes there is still a live credential to hand back.
    @discardableResult
    private func post(body: [String: String]) async -> Bool {
        var req = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""

            guard code == 200 else {
                // 400 on a refresh means the refresh token itself is dead —
                // revoked, or superseded because Strava rotates them. No amount
                // of retrying fixes that; the user must reconnect. Clearing the
                // tokens makes the UI say so instead of failing forever.
                if code == 400, body["grant_type"] == "refresh_token" {
                    disconnect()
                    lastError = "Strava sign-in expired. Tap Connect Strava to reconnect."
                } else {
                    lastError = "Strava auth failed (\(code)) — \(text.prefix(200))"
                }
                return false
            }

            struct R: Decodable {
                let access_token: String
                let refresh_token: String
                let expires_at: TimeInterval
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            let t = StravaTokens(accessToken: r.access_token,
                                 refreshToken: r.refresh_token,
                                 expiresAt: r.expires_at)
            tokens = t
            Keychain.save(t, key: keychainKey)   // Strava ROTATES refresh tokens
            lastError = nil
            return true
        } catch {
            // A cancelled refresh leaves the existing tokens untouched and will
            // be retried on the next call. Reporting it would put "cancelled"
            // in the banner for something that did not go wrong.
            if !error.isCancellation { lastError = error.localizedDescription }
            return false
        }
    }
}

extension StravaAuth: ASWebAuthenticationPresentationContextProviding {
    /// iOS 26 deprecated every UIWindow initialiser except `init(windowScene:)`,
    /// so this never constructs a detached window. In practice one of the first
    /// two branches always returns — ASWebAuthenticationSession only asks for an
    /// anchor while it is presenting, which requires a live scene.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        if let key = scenes.compactMap({ $0.keyWindow }).first { return key }
        if let any = scenes.flatMap({ $0.windows }).first { return any }

        guard let scene = scenes.first else {
            preconditionFailure(
                "No connected UIWindowScene. ASWebAuthenticationSession cannot "
                + "present without one, so this should be unreachable."
            )
        }
        return UIWindow(windowScene: scene)
    }
}

// MARK: - Keychain

enum Keychain {

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func delete(_ key: String) {
        SecItemDelete([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ] as CFDictionary)
    }
}

import UIKit
