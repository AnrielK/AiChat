import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Výběr souborů přes UIDocumentPickerViewController.
///
/// Místo SwiftUI `.fileImporter`: víc importerů v jedné hierarchii (lišta chatu + Nastavení)
/// se umí navzájem rušit a `isPresented` binding se vynuluje dřív, než přijde výsledek
/// (import MLX složky se proto zkoušel jako GGUF). Tady výsledek přijde vždy přímo
/// do `onPick` v delegátovi, s hodnotami zachycenými při otevření.
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    var allowsMultipleSelection = false
    /// true = systém soubor zkopíruje do appky (i z iCloudu, který ještě není stažený).
    /// Pro gigabajtové modely false – kopii si uděláme sami, bez mezikroku v tmp.
    var asCopy = false
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: asCopy)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - Klávesnice

extension UIApplication {
    /// Schová klávesnici, ať je fokus kdekoli.
    func hideKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension View {
    /// Pro formuláře s víceřádkovými poli (systémový prompt): Return tam vkládá nový řádek,
    /// takže klávesnice potřebuje tlačítko „Hotovo“. Navíc ji jde stáhnout tažením seznamu dolů.
    func keyboardDoneButton() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Hotovo") {
                        UIApplication.shared.hideKeyboard()
                    }
                    .fontWeight(.semibold)
                }
            }
    }
}
