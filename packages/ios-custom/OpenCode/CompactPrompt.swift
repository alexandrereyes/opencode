import OpenCodeKit
import SwiftUI

struct CompactPrompt: UIViewRepresentable {
  let text: String
  let theme: AppTheme

  func makeUIView(context: Context) -> UILabel {
    let label = UILabel()
    // The suffix is ours; UILabel must not append a second, native ellipsis.
    label.numberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.font = .systemFont(ofSize: 16)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }
  func updateUIView(_ label: UILabel, context: Context) {
    label.textColor = theme.uiColor(.userBubbleText)
    label.accessibilityLabel = text
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    func fits(_ value: String) -> Bool {
      uiView.text = value
      return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        <= uiView.font.lineHeight * 2 + 1
    }
    let truncated = !fits(normalized)
    if !truncated {
      uiView.text = normalized
    } else {
      var lower = 0
      var upper = normalized.count
      while lower < upper {
        let middle = (lower + upper + 1) / 2
        if fits(ConversationProjection.ellipsis(normalized, count: middle)) {
          lower = middle
        } else {
          upper = middle - 1
        }
      }
      uiView.text = ConversationProjection.ellipsis(normalized, count: lower)
    }
    let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: truncated ? width : size.width, height: size.height)
  }
}
