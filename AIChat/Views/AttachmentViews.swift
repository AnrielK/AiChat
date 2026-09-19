import SwiftUI
import UIKit

/// Štítek přílohy: náhled nebo ikona, název, typ a velikost. S `onRemove` má křížek.
struct AttachmentChip: View {
    let attachment: Attachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            AttachmentThumbnail(attachment: attachment)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Odebrat \(attachment.name)")
            }
        }
        .padding(6)
        .padding(.trailing, onRemove == nil ? 6 : 2)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
    }
}

/// Malý náhled obrázku (načtený mimo hlavní vlákno), u ostatních souborů ikona typu.
struct AttachmentThumbnail: View {
    let attachment: Attachment
    var size: CGFloat = 34

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: attachment.symbol)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.14))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 9))
        .task(id: attachment.id) {
            guard attachment.kind == .image else { return }
            let url = AttachmentStore.fileURL(for: attachment)
            let pixels = CGSize(width: size * 3, height: size * 3)
            image = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let full = UIImage(contentsOfFile: url.path(percentEncoded: false)),
                      full.size.width > 0, full.size.height > 0 else { return nil }
                // Zachovat poměr stran – výřez do čtverce udělá až scaledToFill.
                let scale = max(pixels.width / full.size.width, pixels.height / full.size.height)
                return full.preparingThumbnail(of: CGSize(width: full.size.width * scale, height: full.size.height * scale))
            }.value
        }
    }
}
