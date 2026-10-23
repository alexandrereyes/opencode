import OpenCodeKit
import SwiftUI

struct ResponseMediaTable: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.responseSelection) private var actions
  @Environment(\.responseSelectionChanged) private var selection
  @Environment(\.conversationSearch) private var highlights
  let block: MarkdownBlock
  let table: MarkdownTable
  let source: String
  let messageID: String
  let partID: String
  let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
  let openNote: (String) -> Void
  let wrap: Bool
  var body: some View {
    ScrollView(.horizontal) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(table.rows.indices, id: \.self) { row in
          HStack(alignment: .top, spacing: 0) {
            ForEach(table.rows[row].indices, id: \.self) { column in
              VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(chunks(table.rows[row][column]).enumerated()), id: \.offset) { _, runs in
                  if let image = runs.first?.image {
                    FileTableImage(source: image, name: runs.first?.text ?? "Imagem")
                  } else {
                    SelectableResponseText(block: block.cell(runs, alignment: table.alignments[column]),
                      messageID: messageID, partID: partID, theme: theme, source: source, actions: actions,
                      selectionChanged: selection?.selected, highlights: highlights, rasters: rasters,
                      tableHeader: row == 0, openNote: openNote)
                  }
                }
              }
              .frame(width: wrap ? 200 : 400, alignment: .leading).padding(12)
            }
          }
          .fixedSize(horizontal: false, vertical: true)
          .background(theme.color(.tableSurface))
          .overlay {
            HStack(spacing: 0) {
              ForEach(table.rows[row].indices, id: \.self) { _ in
                Rectangle().strokeBorder(theme.color(.tableSeparator), lineWidth: 0.5)
                  .frame(width: (wrap ? 200 : 400) + 24)
              }
            }.allowsHitTesting(false)
          }
        }
      }
    }.clipShape(RoundedRectangle(cornerRadius: 8))
  }
  private func chunks(_ runs: [MarkdownRun]) -> [[MarkdownRun]] {
    runs.reduce(into: [[MarkdownRun]]()) { result, run in
      if run.image != nil || result.last?.last?.image != nil || result.isEmpty { result.append([run]); return }
      result[result.count - 1].append(run)
    }
  }
}

private struct FileTableImage: View {
  let source: String
  let name: String
  var body: some View {
    if FileViewerKind(path: source) == .audiovisual {
      FileMediaReference(source: source, name: name)
    } else { FeedImageView(source: source, name: name, compact: true) }
  }
}
