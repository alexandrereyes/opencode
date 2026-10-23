import OpenCodeKit
import SwiftUI

struct UserMessageContent<Content: View>: View {
  let maximumHeight: CGFloat
  @ViewBuilder let content: Content
  @State private var height: CGFloat = 1

  var body: some View {
    ScrollView {
      VStack(alignment: .trailing, spacing: 8) { content }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
      .frame(height: min(height, maximumHeight))
  }
}

struct UserMessageAttachments {
  let images: [FeedImage]
  let files: [String]

  init(_ message: ConversationMessage) {
    images = (message.files ?? []).compactMap { file in
      guard let image = FeedImage.attachment(file) else { return nil }
      return FeedImage(source: image.source, name: file.object?["name"]?.string ?? file.object?["filename"]?.string ?? image.name)
    }
    let otherFiles = (message.files ?? []).filter {
      !($0.object?["mime"]?.string ?? $0.object?["mimeType"]?.string ?? "").hasPrefix("image/")
        && $0.object?["type"]?.string != "image"
    }
    let names = otherFiles.map { file in
      if let name = file.object?["name"]?.string ?? file.object?["filename"]?.string { return name }
      if let path = file.object?["uri"]?.string ?? file.object?["path"]?.string ?? file.object?["url"]?.string {
        return URL(fileURLWithPath: path).lastPathComponent
      }
      return "Arquivo anexado"
    }
    // Metadata repeats filenames already represented by native image/file parts.
    let represented = Set(images.map(\.name) + names)
    files = names + (message.metadata?["attachments"]?.array ?? []).map {
      $0.object?["name"]?.string ?? "Arquivo anexado"
    }.filter { !represented.contains($0) }
  }
}

struct UserMessageAttachmentsView: View {
  @Environment(\.appTheme) private var theme
  let attachments: UserMessageAttachments

  var body: some View {
    if !attachments.files.isEmpty {
      UserMessageFileLayout {
        ForEach(Array(attachments.files.enumerated()), id: \.offset) { _, name in
          Label {
            Text(name).lineLimit(1).frame(maxWidth: 140, alignment: .leading).accessibilityHidden(true)
          } icon: {
            Image(systemName: "doc").frame(width: 14, height: 14)
          }.appFont(.caption).foregroundStyle(theme.color(.userBubbleSecondary))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(theme.color(.codeSurface).opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border).opacity(0.3)) }
            .accessibilityRepresentation {
              Text(name).accessibilityHint("Arquivo anexado").accessibilityIdentifier("user-file-\(name)")
            }
        }
      }
    }
    if !attachments.images.isEmpty {
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(Array(attachments.images.enumerated()), id: \.offset) { _, image in
            FeedImageView(source: image.source, name: image.name, thumbnailSize: 48)
          }
        }.padding(.vertical, 2)
      }.scrollIndicators(.hidden).frame(height: 52)
    }
  }
}

private struct UserMessageFileLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = frames(subviews, width: proposal.width ?? .greatestFiniteMagnitude)
    return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (view, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
      view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
    }
  }
  private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var height: CGFloat = 0
    return subviews.map { view in
      let size = view.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width { x = 0; y += height + 6; height = 0 }
      let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
      x += size.width + 6
      height = max(height, size.height)
      return frame
    }
  }
}

struct UserMessageContextCard: View {
  @Environment(\.appTheme) private var theme
  let summary: String
  let text: String
  let comment: String
  let collapsed: Bool
  let id: String
  let expand: () -> Void
  @State private var quoteExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if collapsed {
        Button(action: expand) {
          Label(comment.isEmpty ? summary : "\(summary): \(comment)", systemImage: "quote.bubble")
            .appFont(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityValue("Recolhido")
          .accessibilityLabel("Contexto anexado. \(comment.isEmpty ? summary : "\(summary): \(comment)")")
          .accessibilityHint("Mostrar mensagem completa.")
          .accessibilityIdentifier("user-context-summary-\(id)")
      } else {
        Button {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { quoteExpanded.toggle() }
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Label(summary, systemImage: "quote.bubble").appFont(.caption).lineLimit(1)
            if !text.isEmpty {
              Text(text).appFont(.secondary).lineLimit(quoteExpanded ? nil : 4)
                .multilineTextAlignment(.leading).accessibilityIdentifier("user-context-text-\(id)")
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).disabled(text.isEmpty)
          .accessibilityHint(text.isEmpty ? "" : quoteExpanded ? "Recolher citação" : "Mostrar citação completa")
          .accessibilityIdentifier("user-context-quote-\(id)")
        if !comment.isEmpty {
          Text(comment).appFont(.secondary).foregroundStyle(theme.color(.userBubbleText))
        }
      }
    }.foregroundStyle(theme.color(.userBubbleSecondary)).frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, 12).overlay(alignment: .leading) {
        Rectangle().fill(theme.color(.primary)).frame(width: 2)
      }
  }
}
