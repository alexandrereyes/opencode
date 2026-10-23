import OpenCodeKit
import SwiftUI

struct ResponseCode: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(ToastCenter.self) private var toast
  @Environment(\.responseSelectionChanged) private var selection
  @Environment(\.conversationSearch) private var highlights
  @AppStorage("OpenCodeMarkdownCodeWrap") private var wrap = true
  let block: MarkdownBlock
  let messageID: String
  let partID: String

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        if case .code(let language) = block.kind {
          Text(language?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "texto")
            .appFont(.caption, design: .monospaced).lineLimit(1)
        }
        Spacer(minLength: 8)
        Button { wrap.toggle(); selection?.selected() } label: {
          Image(systemName: "text.word.spacing")
        }
        .accessibilityLabel(wrap ? "Desativar quebra de código" : "Ativar quebra de código")
        .accessibilityValue(wrap ? "Ativada" : "Desativada")
        .accessibilityIdentifier("markdown-code-wrap-\(block.id)")
        Button {
          UIPasteboard.general.string = block.text
          Haptics.play(.selection)
          toast.show("Código copiado")
        } label: { Image(systemName: "doc.on.doc") }
        .accessibilityLabel("Copiar código")
        .accessibilityIdentifier("markdown-code-copy-\(block.id)")
      }
      .buttonStyle(MarkdownToolbarButton())
      .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 2)
      .foregroundStyle(theme.color(.codeHeaderText))
      Rectangle().fill(theme.color(.codeHeaderSeparator).opacity(0.7)).frame(height: 1)
      Group {
        if wrap {
          content
        } else {
          ScrollView(.horizontal) {
            content.frame(width: naturalWidth)
          }
        }
      }.padding(.horizontal, 12).padding(.vertical, 10)
    }
    .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 16))
    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.color(.codeBorder).opacity(0.8), lineWidth: 1) }
  }
  private var content: some View {
    SelectableResponseText(block: block.codeDisplay, messageID: messageID, partID: partID, theme: theme,
      selectionChanged: selection?.selected, highlights: highlights, gutter: true, wrap: wrap)
  }
  private var naturalWidth: CGFloat {
    max(120, block.text.components(separatedBy: "\n").map {
      ($0 as NSString).size(withAttributes: [.font: AppTypography.font(.secondary, monospaced: true,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: typeSize.uiCategory))]).width
    }.max() ?? 0) + UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 44,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: typeSize.uiCategory))
  }
}
