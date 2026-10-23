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
  private var overflowing: Bool {
    readWidth > 0 && (filenames as NSString).size(withAttributes: [.font: AppTypography.font(.caption,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: typeSize.uiCategory))]).width > readWidth
  }
  var body: some View {
    Group {
      switch item.kind {
      case .read:
        HStack(alignment: .top, spacing: 6) {
          Text("Ler").foregroundStyle(theme.color(.textSecondary))
          Text(filenames).lineLimit(readOpen ? nil : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { readWidth = $0 }
          if overflowing || readOpen {
            Image(systemName: readOpen ? "chevron.down" : "chevron.right").appSymbol(.disclosure)
          }
        }
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
        Text(item.parts.count == 1 ? "Carregou a habilidade \(names)" : "Carregou as habilidades \(names)")
          .accessibilityIdentifier("activity-skills-\(item.id)")
      case .search:
        if let part = item.parts.first?.part {
          Text(searchLabel(part)).accessibilityIdentifier("activity-search-\(item.id)")
        }
      case .files:
        if item.files.isEmpty {
          Text(item.parts.first?.part.groupTitle ?? "Patch").foregroundStyle(theme.color(.textSecondary))
        } else {
          ForEach(item.files) { file in
            ConversationActivityFileView(file: file, key: "activity:file:\(item.id):\(file.path)", store: store)
          }
        }
      case .part: EmptyView()
      }
    }.appFont(.caption).foregroundStyle(theme.color(.text))
  }
  private func searchLabel(_ part: ConversationPart) -> String {
    let path = part.input["path"]?.string ?? "/"
    let slash = path.lastIndex(where: { $0 == "/" || $0 == "\\" })
    let parent = slash.map { String(path[...$0]) } ?? "/"
    let root = store.session?.location.directory ?? ""
    let directory = !root.isEmpty && root != "/" && parent.hasPrefix(root + "/") ? String(parent.dropFirst(root.count)) : parent
    let args = (part.name == "list" ? [] : ["pattern", "include"]).compactMap { key in
      part.input[key]?.string.map { "\(key)=\($0)" }
    }
    let count = part.metadata[part.name == "glob" ? "count" : "matches"]?.number
    return ([part.groupTitle, directory] + args).joined(separator: " ")
      + (count.flatMap { $0.isFinite && $0 != 0 ? " (\(Int($0)) \($0 == 1 ? "correspondência" : "correspondências"))" : nil } ?? "")
  }
}

private struct ConversationActivityFileView: View {
  @Environment(\.appTheme) private var theme
  let file: ConversationActivityFile
  let key: String
  let store: ConversationStore
  private var expanded: Bool { store.expansionValues[key] == true }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { store.expansionValues[key] = !expanded }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "doc.text")
          Text(file.path).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
          if file.status == "added" { Text("Criado").foregroundStyle(theme.color(.diffAdd)) }
          else if file.status == "deleted" { Text("Excluído").foregroundStyle(theme.color(.diffDelete)) }
          else {
            Text("+\(file.additions)").foregroundStyle(theme.color(.diffAdd))
            Text("−\(file.deletions)").foregroundStyle(theme.color(.diffDelete))
          }
          Image(systemName: expanded ? "chevron.down" : "chevron.right").appSymbol(.disclosure)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(theme.color(.toolSurface), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(theme.color(.borderStrong), lineWidth: 0.5) }
        .contentShape(Rectangle())
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
}
