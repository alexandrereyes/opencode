import OpenCodeKit
import SwiftUI

struct CompactPrompt: UIViewRepresentable {
  let text: String
  let theme: AppTheme

  func makeUIView(context: Context) -> CompactPromptLabel {
    let label = CompactPromptLabel()
    // The suffix is ours; UILabel must not append a second, native ellipsis.
    label.numberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.font = .systemFont(ofSize: 16)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }
  func updateUIView(_ label: CompactPromptLabel, context: Context) {
    label.textColor = theme.uiColor(.userBubbleText)
    label.accessibilityLabel = text
    if label.source != text {
      label.source = text
      label.normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      label.measurements.removeAll(keepingCapacity: true)
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: CompactPromptLabel, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    if let measured = uiView.measurements[width] {
      if uiView.text != measured.text { uiView.text = measured.text }
      return measured.size
    }
    let normalized = uiView.normalized
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
    let result = CGSize(width: truncated ? width : size.width, height: size.height)
    if uiView.measurements.count >= 8 { uiView.measurements.removeAll(keepingCapacity: true) }
    uiView.measurements[width] = (uiView.text ?? "", result)
    return result
  }
}

final class CompactPromptLabel: UILabel {
  var source = ""
  var normalized = ""
  var measurements: [CGFloat: (text: String, size: CGSize)] = [:]
}
