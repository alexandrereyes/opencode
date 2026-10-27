import OpenCodeKit
import SwiftUI

/// The vertical timeline inside an activity card: one thin line through the rows' dots, drawn from the
/// first dot to the last one so it never runs past the ends.
struct ConversationTimeline<Content: View>: View {
  @Environment(\.appTheme) private var theme
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) { content() }
      .frame(maxWidth: .infinity, alignment: .leading)
      .backgroundPreferenceValue(ConversationTimelineDots.self) { dots in
        GeometryReader { proxy in
          let points = dots.map { proxy[$0] }
          if let first = points.min(by: { $0.y < $1.y }), let last = points.max(by: { $0.y < $1.y }), first != last {
            Path { path in
              path.move(to: first)
              path.addLine(to: CGPoint(x: first.x, y: last.y))
            }.stroke(theme.color(.borderStrong), lineWidth: 1)
          }
        }
      }
  }
}

/// One timeline entry: its dot (primary once finished, gray otherwise) centered on the first text line.
struct ConversationTimelineRow<Content: View>: View {
  let done: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ConversationTimelineDot(done: done)
      VStack(alignment: .leading, spacing: 8) { content() }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ConversationTimelineDot: View {
  @Environment(\.appTheme) private var theme
  /// Centers the dot on the first line of caption text: half its line height less half the dot.
  @ScaledMetric(relativeTo: .footnote) private var inset: CGFloat = 4.5
  let done: Bool

  var body: some View {
    Circle().fill(theme.color(done ? .primary : .textWeak)).frame(width: 7, height: 7)
      .anchorPreference(key: ConversationTimelineDots.self, value: .center) { [$0] }
      .padding(.top, inset)
      .accessibilityHidden(true)
  }
}

/// A timeline entry's first line: line icon, the tool's name, its target in monospace, an optional accessory
/// (a subagent's chip and button) and, when known, the duration at the trailing edge.
struct ConversationTimelineLabel<Accessory: View>: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  let icon: String
  let name: String
  var target = ""
  /// Paths, commands and queries are monospaced; a subagent's description is prose.
  var monospaced = true
  var tone: ThemeRole = .text
  var duration: String?
  /// Nil lets the name and target wrap freely.
  var lines: Int? = 2
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    Group {
      // Accessibility sizes give the name and target the whole line, with the accessory and duration below.
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            symbol
            label
          }
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            accessory()
            Spacer(minLength: 4)
            time
          }.padding(.leading, 26)
        }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          symbol
          label.lineLimit(lines).layoutPriority(1)
          accessory()
          Spacer(minLength: 4)
          time
        }
      }
    }.appFont(.caption)
  }

  /// A text glyph on the name's baseline. Its short frame lets tall symbols (the failure triangle) overhang
  /// instead of making the first line taller than the text, which would move it off the row's dot.
  private var symbol: some View {
    Text(Image(systemName: icon)).appSymbol(.inline, weight: .regular).foregroundStyle(theme.color(tone == .text ? .icon : tone))
      .frame(width: 18, height: 10).accessibilityHidden(true)
  }

  private var label: some View {
    Text("\(Text(name).foregroundStyle(theme.color(tone == .text ? .textSecondary : tone)))\(Text(target.isEmpty ? "" : (monospaced ? "  " : " ") + target).monospaced(monospaced).foregroundStyle(theme.color(tone)))")
      .truncationMode(monospaced ? .middle : .tail).multilineTextAlignment(.leading)
  }

  @ViewBuilder private var time: some View {
    if let duration {
      Text(duration).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).lineLimit(1).fixedSize()
    }
  }
}

extension ConversationTimelineLabel where Accessory == EmptyView {
  init(icon: String, name: String, target: String = "", tone: ThemeRole = .text, duration: String? = nil, lines: Int? = 2) {
    self.init(icon: icon, name: name, target: target, tone: tone, duration: duration, lines: lines) { EmptyView() }
  }
}

struct ConversationTimelineDots: PreferenceKey {
  static let defaultValue: [Anchor<CGPoint>] = []
  static func reduce(value: inout [Anchor<CGPoint>], nextValue: () -> [Anchor<CGPoint>]) {
    value += nextValue()
  }
}
