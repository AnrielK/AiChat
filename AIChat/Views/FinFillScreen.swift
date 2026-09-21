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
                        Image(systemName: auth.isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark")
                    }
                    .accessibilityLabel("Google účet")
                }
            }
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
                    Text(auth.isSignedIn ? "Přihlášeno" : "Nepřihlášeno")
                        .foregroundStyle(auth.isSignedIn ? .green : .secondary)
                }
                if auth.isSignedIn {
                    Button("Odhlásit", role: .destructive) { auth.signOut() }
                } else {
                    Button {
                        Task {
                            do { try await auth.signIn() } catch { auth.lastError = error.localizedDescription }
                        }
                    } label: {
                        if auth.isWorking { ProgressView() } else { Text("Přihlásit se ke Google") }
                    }
                    .disabled(auth.redirectScheme == nil || auth.isWorking)
                }
            } footer: {
                if let error = auth.lastError { Text(error).foregroundStyle(.red) }
            }

            Section("Jak získat client ID") {
                Text("""
                1. console.cloud.google.com → nový projekt → APIs & Services → Enable APIs → Google Sheets API.
                2. OAuth consent screen: External, stav Testing, přidej svůj Gmail mezi Test users, scope …/auth/spreadsheets.
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
}
