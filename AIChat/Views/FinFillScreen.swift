import SwiftUI
import FinFillCore
import FinFillUI

/// 10-K ze SEC → Google Sheets (šablona valuace) + souhrn modelem vybraným v Nastavení.
struct FinFillScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ModelManager.self) private var models
    private let auth = GoogleAuth.shared

    var body: some View {
        FinFillView(tokens: GoogleTokenProvider(),
                    engine: FinFillEngine.current(settings: settings, models: models))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        GoogleAccountView()
                    } label: {
                        Image(systemName: accountSymbol)
                    }
                    .accessibilityLabel("Google účet")
                }
            }
    }

    private var accountSymbol: String {
        auth.isSignedIn && auth.hasAllScopes ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
    }
}

/// Client ID + přihlášení ke Google (jen pro zápis do Google Sheets).
struct GoogleAccountView: View {
    @State private var auth = GoogleAuth.shared

    var body: some View {
        Form {
            Section {
                TextField("…apps.googleusercontent.com", text: $auth.clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
            } header: {
                Text("iOS OAuth client ID")
            } footer: {
                if auth.clientID.isEmpty {
                    EmptyView()
                } else if let scheme = auth.redirectScheme {
                    Text("Návrat z přihlášení: \(scheme):/oauth2redirect")
                } else {
                    Text("Client ID má končit na .apps.googleusercontent.com").foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Stav") {
                    Text(statusText).foregroundStyle(statusColor)
                }
                if auth.isSignedIn && auth.hasAllScopes {
                    Button("Odhlásit", role: .destructive) { auth.signOut() }
                } else {
                    Button {
                        Task {
                            do { try await auth.signIn() } catch { auth.lastError = error.localizedDescription }
                        }
                    } label: {
                        if auth.isWorking {
                            ProgressView()
                        } else {
                            Text(signInTitle)
                        }
                    }
                    .disabled(auth.redirectScheme == nil || auth.isWorking)
                }
            } footer: {
                if let error = auth.lastError { Text(error).foregroundStyle(.red) }
            }

            Section("Jak získat client ID") {
                Text("""
                1. console.cloud.google.com → nový projekt → APIs & Services → Enable APIs → Google Sheets API a Google Drive API.
                2. OAuth consent screen: External, stav Testing, přidej svůj Gmail mezi Test users, scopes …/auth/spreadsheets a …/auth/drive.metadata.readonly (jen názvy souborů pro výběr sešitu).
                3. Credentials → Create OAuth client ID → iOS, Bundle ID: \(Bundle.main.bundleIdentifier ?? "—").
                4. Client ID vlož sem a přihlas se.

                V režimu Testing platí přihlášení 7 dní, pak se aplikace zeptá znovu.
                """)
                .font(.footnote)
                .textSelection(.enabled)
            }
        }
        .navigationTitle("Google účet")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        if !auth.isSignedIn { return "Nepřihlášeno" }
        return auth.hasAllScopes ? "Přihlášeno" : "Chybí oprávnění"
    }

    private var statusColor: Color {
        if !auth.isSignedIn { return Color.secondary }
        return auth.hasAllScopes ? Color.green : Color.orange
    }

    private var signInTitle: String {
        auth.isSignedIn ? "Přihlásit znovu (přidat přístup k seznamu sešitů)" : "Přihlásit se ke Google"
    }
}
