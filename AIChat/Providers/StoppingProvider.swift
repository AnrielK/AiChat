import Foundation

/// Zastaví generování, jakmile v odpovědi padne jedna ze značek.
///
/// Bez toho model po zapsání volání nástroje pokračuje dál a dopíše si i jeho výsledek –
/// smyšlený. Uživatel na to čeká a zaplatí za to tokeny, které se stejně zahodí.
///
/// Funguje nad libovolným poskytovatelem: když se přestane odebírat ze streamu,
/// `AsyncThrowingStream` zruší úlohu pod ním a engine generování opravdu ukončí
/// (`MLXEngine` i `LlamaEngine` mají ve smyčce `Task.isCancelled`). U MLX je navíc
/// značka předaná až do generační smyčky, takže se nečeká ani na zrušení.
///
/// Text se posílá dál po kouscích, ale se zpožděním o délku nejdelší značky – jinak
/// by se `>>` z volání nástroje stihlo objevit uživateli na obrazovce.
struct StoppingProvider: ChatProvider {
    let base: any ChatProvider
    let sequences: [String]

    func oneShot() -> any ChatProvider {
        StoppingProvider(base: base.oneShot(), sequences: sequences)
    }

    func stopping(at sequences: [String]) -> any ChatProvider {
        StoppingProvider(base: base, sequences: self.sequences + sequences)
    }

    func stream(_ history: [ChatTurn]) -> AsyncThrowingStream<StreamEvent, Error> {
        let sequences = self.sequences.filter { !$0.isEmpty }
        guard !sequences.isEmpty else { return base.stream(history) }
        let hold = (sequences.map(\.count).max() ?? 1) - 1

        return AsyncThrowingStream { continuation in
            let task = Task {
                var pending = ""
                do {
                    loop: for try await event in base.stream(history) {
                        guard case .text(let piece) = event else {
                            continuation.yield(event)
                            continue
                        }
                        pending += piece
                        if let cut = Self.firstMatch(of: sequences, in: pending) {
                            let kept = String(pending[pending.startIndex..<cut])
                            if !kept.isEmpty { continuation.yield(.text(kept)) }
                            break loop
                        }
                        // Konec bufferu se drží: značka může být rozdělená mezi dva kousky.
                        if pending.count > hold {
                            let safe = pending.index(pending.endIndex, offsetBy: -hold)
                            continuation.yield(.text(String(pending[pending.startIndex..<safe])))
                            pending = String(pending[safe...])
                        }
                    }
                    if !pending.isEmpty, Self.firstMatch(of: sequences, in: pending) == nil {
                        continuation.yield(.text(pending))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Index začátku první značky, která se v textu objeví.
    private static func firstMatch(of sequences: [String], in text: String) -> String.Index? {
        sequences.compactMap { text.range(of: $0)?.lowerBound }.min()
    }
}

extension ChatProvider {
    /// Kopie, která přestane generovat na některé ze značek. Výchozí implementace
    /// obalí poskytovatele `StoppingProvider`em; engine, který značky umí sám
    /// (MLX), si ji přebije vlastní.
    func stopping(at sequences: [String]) -> any ChatProvider {
        StoppingProvider(base: self, sequences: sequences)
    }
}
