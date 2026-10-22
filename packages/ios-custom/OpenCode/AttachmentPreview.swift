import OpenCodeKit
import SwiftUI

struct AttachmentPreview: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var scale
  let encoded: String
  let name: String
  @State private var image: CGImage?
  @State private var loading = true
  @State private var measuredHeight: CGFloat?

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let image {
        Image(decorative: image, scale: scale).resizable().scaledToFit()
          .frame(maxWidth: 160, maxHeight: 110)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        Label(name, systemImage: "photo").font(.caption)
      } else {
        HStack(spacing: 8) {
          Image(systemName: "photo").font(.title3)
          VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption.weight(.medium)).lineLimit(1)
            Text(loading ? "Carregando imagem…" : "Imagem indisponível").font(.caption2)
          }
        }.padding(10).background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .frame(minHeight: loading ? measuredHeight : nil)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: { _, height in
      if !loading { measuredHeight = height }
    }
    .foregroundStyle(theme.color(.textSecondary)).accessibilityElement(children: .combine)
    .task(id: encoded) {
      loading = true
      let maximum = Int(ceil(160 * scale))
      let result = await Task.detached(priority: .userInitiated) {
        Data(base64Encoded: encoded).flatMap {
          AttachmentImage.thumbnail($0, maxPixelSize: maximum)
        }
      }.value
      guard !Task.isCancelled else { return }
      image = result
      loading = false
    }
    .onDisappear {
      image = nil
      loading = true
    }
  }
}
