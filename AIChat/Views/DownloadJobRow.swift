import SwiftUI

/// Řádek běžícího stahování: název, průběh, zrušit / zkusit znovu.
struct DownloadJobRow: View {
    let job: DownloadJob
    private let downloads = DownloadManager.shared

    var body: some View {
        let failed = job.state == .failed
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KindBadge(kind: job.kind)
                Text(job.title).lineLimit(1)
                Spacer()
                if failed {
                    Button {
                        downloads.retry(job)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill").font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Zkusit znovu")
                }
                Button {
                    downloads.cancel(job)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Zrušit stahování")
            }
            ProgressView(value: job.state == .installing ? nil : downloads.fraction(job))
                .tint(failed ? Color.orange : Color.accentColor)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(failed ? Color.orange : Color.secondary)
                .monospacedDigit()
        }
    }

    private var statusText: String {
        switch job.state {
        case .failed:
            return job.errorMessage ?? "Stahování selhalo."
        case .installing:
            return "Instaluji…"
        case .downloading:
            let received = ByteCountFormatter.string(fromByteCount: downloads.bytesReceived(job), countStyle: .file)
            let total = downloads.totalBytes(job)
            var text = total > 0
                ? "\(received) z \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                : received
            if job.files.count > 1 {
                text += " · soubory \(job.completed.count)/\(job.files.count)"
            }
            return text
        }
    }
}

/// Stav modelu v řádku seznamu: staženo ✓, průběh v %, chyba, nebo nic (nil = lze stáhnout).
struct DownloadStatusBadge: View {
    let modelID: String
    @Environment(ModelManager.self) private var models
    private let downloads = DownloadManager.shared

    /// Má smysl zobrazit badge? Když ne, řádek ukáže tlačítko ke stažení.
    static func isActive(_ modelID: String, models: ModelManager) -> Bool {
        models.model(id: modelID) != nil || DownloadManager.shared.isBusy(modelID)
    }

    var body: some View {
        if models.model(id: modelID) != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("Staženo")
        } else if let job = downloads.job(for: modelID) {
            if job.state == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Stahování selhalo")
            } else {
                Text(downloads.fraction(job).map { "\(Int($0 * 100)) %" } ?? "…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if downloads.preparing.contains(modelID) {
            ProgressView()
        }
    }
}
