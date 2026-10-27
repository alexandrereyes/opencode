import OpenCodeKit
import SwiftUI

struct ConversationActivityItemView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  let item: ConversationActivityItem
  let store: ConversationStore
  @State private var readWidth: CGFloat = 0
  private var readKey: String { "activity:read:\(item.id)" }
  private var readOpen: Bool { store.expansionValues[readKey] == true }
  private var filenames: String {
    let names = item.parts.map { $0.part.readGroupName }.filter { !$0.isEmpty }
    return names.count > 1 ? names.dropLast().joined(separator: ", ") + " e " + names.last! : names.first ?? ""
  }
  /// Whether the one-line filenames would be cut: the line's measured width against the icon, "Ler", the
  /// monospaced names and the duration laid out by `ConversationTimelineLabel`.
  private var overflowing: Bool {
    // Accessibility sizes wrap the names in full.
    guard readWidth > 0, !typeSize.isAccessibilitySize else { return false }
    let traits = UITraitCollection(preferredContentSizeCategory: typeSize.uiCategory)
    let regular = AppTypography.font(.caption, compatibleWith: traits)
    let width = { (text: String, font: UIFont) in (text as NSString).size(withAttributes: [.font: font]).width }
    let duration = item.duration.map { width(ConversationProjection.duration($0), regular) + 12 } ?? 0
    return 26 + width("Ler", regular) + width("  " + filenames, AppTypography.font(.caption, monospaced: true,
      compatibleWith: traits)) + duration > readWidth
  }
  var body: some View {
    let duration = item.duration.map(ConversationProjection.duration)
    switch item.kind {
    case .read:
      ConversationTimelineLabel(icon: "doc.text", name: "Ler", target: filenames, duration: duration,
        lines: readOpen ? nil : 1) {
        if overflowing || readOpen {
          Image(systemName: readOpen ? "chevron.down" : "chevron.right").appSymbol(.disclosure)
            .foregroundStyle(theme.color(.icon))
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { readWidth = $0 }
      .contentShape(Rectangle()).onTapGesture {
        guard overflowing || readOpen else { return }
        store.expansionValues[readKey] = !readOpen
      }
      .accessibilityElement(children: .ignore).accessibilityLabel("Ler " + filenames)
      .accessibilityValue(readOpen ? "Expandido" : "Recolhido")
      .accessibilityAddTraits(overflowing || readOpen ? .isButton : [])
      .accessibilityIdentifier("activity-read-\(item.id)")
    case .skills:
      let names = item.parts.compactMap { $0.part.skillName }.joined(separator: ", ")
      ConversationTimelineLabel(icon: "sparkles", name: item.parts.count == 1 ? "Carregou a habilidade" : "Carregou as habilidades",
        target: names, duration: duration)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.parts.count == 1 ? "Carregou a habilidade \(names)" : "Carregou as habilidades \(names)")
        .accessibilityIdentifier("activity-skills-\(item.id)")
    case .search:
      if let part = item.parts.first?.part {
        ConversationTimelineLabel(icon: part.icon, name: part.groupTitle, target: searchTarget(part), duration: duration)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel([part.groupTitle, searchTarget(part)].joined(separator: " "))
          .accessibilityIdentifier("activity-search-\(item.id)")
      }
    case .files:
      let title = item.parts.first?.part.groupTitle ?? "Patch"
      if item.files.count == 1, let file = item.files.first {
        ConversationActivityFileView(file: file, key: "activity:file:\(item.id):\(file.path)", store: store,
          title: title, duration: duration)
      } else {
        ConversationTimelineLabel(icon: "pencil", name: title,
          target: item.files.isEmpty ? "" : "\(item.files.count) arquivos", monospaced: false, duration: duration) { EmptyView() }
        ForEach(item.files) { file in
          ConversationActivityFileView(file: file, key: "activity:file:\(item.id):\(file.path)", store: store)
            .padding(.leading, 26)
        }
      }
    case .part: EmptyView()
    }
  }
  /// The searched directory relative to the session's, the pattern and the match count.
  private func searchTarget(_ part: ConversationPart) -> String {
    let path = part.input["path"]?.string ?? "/"
    let slash = path.lastIndex(where: { $0 == "/" || $0 == "\\" })
    let parent = slash.map { String(path[...$0]) } ?? "/"
    let root = store.session?.location.directory ?? ""
    let directory = !root.isEmpty && root != "/" && parent.hasPrefix(root + "/") ? String(parent.dropFirst(root.count)) : parent
    let args = (part.name == "list" ? [] : ["pattern", "include"]).compactMap { key in
      part.input[key]?.string.map { "\(key)=\($0)" }
    }
    let count = part.metadata[part.name == "glob" ? "count" : "matches"]?.number
    return ([directory] + args).joined(separator: " ")
      + (count.flatMap { $0.isFinite && $0 != 0 ? " (\(Int($0)) \($0 == 1 ? "correspondência" : "correspondências"))" : nil } ?? "")
  }
}

/// One edited file: its path, `+N −M` (or Criado/Excluído) and a disclosure for its diff. A single-file
/// item draws it on the timeline line itself, after the tool's name.
private struct ConversationActivityFileView: View {
  @Environment(\.appTheme) private var theme
  let file: ConversationActivityFile
  let key: String
  let store: ConversationStore
  var title: String?
  var duration: String?
  private var expanded: Bool { store.expansionValues[key] == true }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { store.expansionValues[key] = !expanded }
      } label: {
        Group {
          if let title {
            ConversationTimelineLabel(icon: "pencil", name: title, target: (file.path as NSString).lastPathComponent,
              duration: duration, lines: 1) { counts }
          } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(file.path).monospaced().lineLimit(1).truncationMode(.middle)
              counts
              Spacer(minLength: 0)
            }.appFont(.caption)
          }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("activity-file-\(key)")
        .accessibilityValue(expanded ? "Expandido" : "Recolhido")
      if expanded {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(file.patches.enumerated()), id: \.offset) { _, patch in
            ForEach(Array(ConversationPart.patchLines(patch).enumerated()), id: \.offset) { _, line in
              Text(line).foregroundStyle(theme.color(line.hasPrefix("+") ? .diffAdd : line.hasPrefix("-") ? .diffDelete : .text))
            }
          }
        }.appFont(.caption, design: .monospaced).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(8)
          .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }
  @ViewBuilder private var counts: some View {
    HStack(spacing: 6) {
      if file.status == "added" { Text("Criado").foregroundStyle(theme.color(.diffAdd)) }
      else if file.status == "deleted" { Text("Excluído").foregroundStyle(theme.color(.diffDelete)) }
      else {
        Text("+\(file.additions)").foregroundStyle(theme.color(.diffAdd))
        Text("−\(file.deletions)").foregroundStyle(theme.color(.diffDelete))
      }
      Image(systemName: expanded ? "chevron.down" : "chevron.right").appSymbol(.disclosure)
        .foregroundStyle(theme.color(.icon))
    }.appFont(.caption).monospacedDigit().fixedSize()
  }
}
