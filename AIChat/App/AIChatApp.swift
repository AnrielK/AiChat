import SwiftUI
import SwiftData
import UIKit

@main
struct AIChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = SettingsStore()
    @State private var models = ModelManager()
    private let container: ModelContainer
    private let storageError: String?

    init() {
        // Background URLSession musí existovat hned po startu, jinak nedostane své události.
        _ = DownloadManager.shared

        // Kontejner vlastní, ne `.modelContainer(for:)`: když se databázi nepodaří otevřít
        // (třeba nepovedená migrace), modifikátor to jen zaloguje a chaty pak „mizí“.
        // Tady se chyba ukáže a původní soubor zůstane nedotčený pro pozdější opravu.
        do {
            container = try ModelContainer(for: Conversation.self, ChatMessage.self, TrainingSample.self)
            storageError = nil
        } catch {
            let memory = ModelConfiguration(isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            container = try! ModelContainer(for: Conversation.self, ChatMessage.self, TrainingSample.self, configurations: memory)
            storageError = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(storageError: storageError)
                .environment(settings)
                .environment(models)
        }
        .modelContainer(container)
    }
}

/// Když stahování doběhne ve chvíli, kdy appka neběží, systém ji na pozadí probudí
/// a předá completion handler – zavolá se, až session doručí všechny události.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}
