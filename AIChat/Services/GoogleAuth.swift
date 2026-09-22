import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import FinFillCore

/// Přihlášení ke Google účtu kvůli zápisu do Google Sheets (FinFill).
///
/// Bez Google SDK: OAuth 2 „authorization code + PKCE“ pro iOS klienta. Okno přihlášení otevře
/// `ASWebAuthenticationSession`, návrat na `com.googleusercontent.apps.…:/oauth2redirect`
/// zachytí sama (URL scheme v Info.plist není potřeba). Refresh token leží v Klíčence,
/// access token jen v paměti (platí hodinu, obnovuje se sám).
@MainActor
@Observable
final class GoogleAuth {
    static let shared = GoogleAuth()
    /// Zápis do sešitů + seznam souborů pro výběr sešitu (jen názvy, ne obsah).
    static let scopes = ["https://www.googleapis.com/auth/spreadsheets", GoogleDriveClient.scope]
    private static let clientIDKey = "google.oauth.clientID"
    private static let grantedKey = "google.oauth.scopes"

    /// iOS OAuth client ID z Google Cloud Console („…apps.googleusercontent.com“). Není tajný.
    var clientID: String = UserDefaults.standard.string(forKey: GoogleAuth.clientIDKey) ?? "" {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIDKey) }
    }
    private(set) var isSignedIn = KeychainHelper.read(.googleRefresh) != nil
    /// Oprávnění, která uživatel opravdu udělil (Google dovolí některá odškrtnout).
    private(set) var grantedScopes = Set((UserDefaults.standard.string(forKey: GoogleAuth.grantedKey) ?? "").split(separator: " ").map(String.init))
    /// Přihlášení z dřívější verze nemá oprávnění k Disku – je potřeba se přihlásit znovu.
    var hasAllScopes: Bool { Set(Self.scopes).isSubset(of: grantedScopes) }
    /// Zápis do sešitů je nutný; seznam souborů (Disk) je jen pohodlí – když ho uživatel
    /// při souhlasu odškrtne, výběr sešitu ohlásí chybu a URL jde zadat ručně.
    private var canWriteSheets: Bool { grantedScopes.contains(Self.scopes[0]) }
    private(set) var isWorking = false
    var lastError: String?

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var session: ASWebAuthenticationSession?
    private let anchor = AuthAnchor()

    enum AuthError: LocalizedError {
        case noClientID, cancelled, badResponse(String)
        var errorDescription: String? {
            switch self {
            case .noClientID: "Doplň iOS OAuth client ID v Nastavení › Google účet."
            case .cancelled: "Přihlášení ke Google bylo zrušeno."
            case .badResponse(let m): "Google OAuth: \(m)"
            }
        }
    }

    /// „123-abc.apps.googleusercontent.com“ → „com.googleusercontent.apps.123-abc“
    var redirectScheme: String? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return "com.googleusercontent.apps." + id.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    /// Platný access token; když chybí, obnoví ho z refresh tokenu, případně otevře přihlášení.
    func validAccessToken() async throws -> String {
        if let token = accessToken, expiry.timeIntervalSinceNow > 60, canWriteSheets { return token }
        if let refresh = KeychainHelper.read(.googleRefresh), canWriteSheets {
            do {
                return try await refreshAccess(with: refresh)
            } catch {
                // Refresh token vypršel (u projektu ve stavu „Testing“ po 7 dnech) – přihlásit znovu.
                KeychainHelper.delete(.googleRefresh)
                isSignedIn = false
            }
        }
        try await signIn()
        guard let token = accessToken else { throw AuthError.badResponse("chybí access token") }
        return token
    }

    func signIn() async throws {
        guard let scheme = redirectScheme else { throw AuthError.noClientID }
        isWorking = true
        defer { isWorking = false }
        lastError = nil

        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let redirect = scheme + ":/oauth2redirect"
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "include_granted_scopes", value: "true"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: comps.url!, callback: .customScheme(scheme)) { url, error in
                if let url { continuation.resume(returning: url) }
                else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.cancelled)
                }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw AuthError.badResponse(error) }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.badResponse("chybí code") }

        let json = try await tokenRequest([
            "client_id": clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw AuthError.badResponse("Google neposlal refresh token") }
        KeychainHelper.save(refresh, for: .googleRefresh)
        isSignedIn = true
        apply(json)
    }

    func signOut() {
        if let refresh = KeychainHelper.read(.googleRefresh) {
            // Odvolání tokenu u Google, výsledek není podstatný.
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(("token=" + refresh).utf8)
            Task.detached { _ = try? await URLSession.shared.data(for: req) }
        }
        KeychainHelper.delete(.googleRefresh)
        UserDefaults.standard.removeObject(forKey: Self.grantedKey)
        grantedScopes = []
        accessToken = nil
        expiry = .distantPast
        isSignedIn = false
    }

    private func refreshAccess(with refresh: String) async throws -> String {
        let json = try await tokenRequest(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
        apply(json)
        guard let token = accessToken else { throw AuthError.badResponse("chybí access token") }
        return token
    }

    private func apply(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        if let scope = json["scope"] as? String {
            grantedScopes = Set(scope.split(separator: " ").map(String.init))
            UserDefaults.standard.set(scope, forKey: Self.grantedKey)
        }
        let seconds = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 3_600
        expiry = Date().addingTimeInterval(seconds)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/:")
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (json["error_description"] as? String) ?? (json["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AuthError.badResponse(message)
        }
        return json
    }

    private static func randomURLSafe(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URL
    }
}

/// Token pro `GoogleSheetsClient` (FinFill).
struct GoogleTokenProvider: AccessTokenProvider {
    func accessToken() async throws -> String {
        try await GoogleAuth.shared.validAccessToken()
    }
}

/// Okno, nad kterým se ukáže přihlášení.
private final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
            return UIWindow(windowScene: scenes.first!)
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
