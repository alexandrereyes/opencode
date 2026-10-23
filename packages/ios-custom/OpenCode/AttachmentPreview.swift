import OpenCodeKit
import SwiftUI

struct ConversationImageContext {
  let client: OpenCodeClient
  let directory: String
  let sessionID: String
}

extension EnvironmentValues {
  @Entry var conversationImages: ConversationImageContext? = nil
}

struct AttachmentPreview: View {
  let encoded: String
  let name: String
  var body: some View {
    FeedImageView(source: "data:image/png;base64,\(encoded)", name: name, compact: true)
  }
}

private struct FeedImageLoadID: Hashable {
  let source: String
  let directory: String?
  let attempt: Int
}

struct FeedImageView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var scale
  @Environment(\.conversationImages) private var context
  let source: String
  var name = "Imagem"
  var compact = false
  var thumbnailSize: CGFloat? = nil
  @State private var image: CGImage?
  @State private var failure: FeedImageFailure?
  @State private var open = false
  @State private var attempt = 0
  @State private var measuredHeight: CGFloat?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let thumbnailSize {
        Button {
          if image != nil { open = true }
          if failure != nil { attempt += 1 }
        } label: {
          Group {
            if let image {
              Image(decorative: image, scale: scale).resizable().scaledToFill()
            } else if failure != nil {
              Image(systemName: "photo.badge.exclamationmark")
            } else { ProgressView() }
          }.frame(width: thumbnailSize, height: thumbnailSize).clipped()
            .background(theme.color(.codeSurface).opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border).opacity(0.4)) }
        }.buttonStyle(.plain).frame(width: thumbnailSize, height: thumbnailSize)
          .contentShape(Rectangle())
          .accessibilityLabel(failure == nil ? "Abrir imagem anexada: \(name)" : "Imagem anexada indisponível: \(name)")
          .accessibilityHint(failure == nil ? "" : "Tentar novamente")
          .accessibilityIdentifier(image == nil ? "feed-image-placeholder-\(name)" : "feed-image-\(name)")
      } else {
      if let image {
        Button { open = true } label: {
          Image(decorative: image, scale: scale).resizable().scaledToFit()
            .frame(maxWidth: compact ? 160 : .infinity, maxHeight: compact ? 110 : 300)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Abrir imagem: \(name)")
        .accessibilityIdentifier("feed-image-\(name)")
      } else {
        VStack(alignment: .leading, spacing: 7) {
          if let failure {
            Label("Imagem indisponível no iPhone", systemImage: "photo.badge.exclamationmark")
              .font(.subheadline.weight(.medium))
            Text(FeedImageReference.display(source)).font(.caption).lineLimit(3)
              .textSelection(.enabled)
            Text(failure.localizedDescription).font(.caption)
            Button("Tentar novamente") { attempt += 1 }.font(.caption)
          } else {
            HStack(spacing: 10) { ProgressView(); Text("Carregando imagem…").font(.caption) }
              .frame(height: compact ? 70 : 140)
          }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
          .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 10))
          .accessibilityIdentifier("feed-image-placeholder-\(name)")
      }
      if !name.isEmpty && name != "Imagem" {
        Text(name).font(.caption).lineLimit(2)
      }
      }
    }
    .frame(minHeight: image == nil && failure == nil ? measuredHeight : nil)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, height in
      if image != nil { measuredHeight = height }
    }
    .foregroundStyle(theme.color(.textSecondary))
    .task(id: FeedImageLoadID(source: source, directory: context?.directory, attempt: attempt)) {
      image = nil
      failure = nil
      guard let context else { failure = .unavailable; return }
      do {
        let loaded = try await FeedImageLoader.shared.load(source, client: context.client,
          directory: context.directory, maxPixelSize: Int((thumbnailSize ?? (compact ? 160 : 400)) * scale))
        guard !Task.isCancelled else { return }
        image = loaded
      } catch {
        guard !Task.isCancelled else { return }
        failure = FeedImageFailure.map(error)
      }
    }
    .fullScreenCover(isPresented: $open) {
      FeedImageFullscreen(source: source, name: name).environment(\.conversationImages, context)
        .floatingVoiceInset()
        .modifier(FloatingVoiceScope())
    }
    .onDisappear { image = nil }
  }
}

private struct FeedImageFullscreen: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.conversationImages) private var context
  let source: String
  let name: String
  @State private var image: CGImage?
  @State private var failure: FeedImageFailure?
  @State private var attempt = 0
  var body: some View {
    NavigationStack {
      Group {
        if let image {
          ZoomableImageView(image: image, name: name) { dismiss() }
        } else if let failure {
          VStack(spacing: 12) {
            Text("Imagem indisponível no iPhone")
            Text(FeedImageReference.display(source)).font(.caption).lineLimit(3)
              .textSelection(.enabled)
            Text(failure.localizedDescription).font(.caption)
            Button("Tentar novamente") { attempt += 1 }
          }.foregroundStyle(theme.color(.textSecondary))
        } else {
          ProgressView("Carregando imagem…")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.color(.background)).navigationTitle(name).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } }
        ToolbarItemGroup(placement: .topBarLeading) { FeedImageFileActions(source: source, name: name) }
      }
    }.tint(theme.color(.primary))
      .task(id: attempt) {
        guard let context else { failure = .unavailable; return }
        failure = nil
        do {
          let loaded = try await FeedImageLoader.shared.load(source, client: context.client,
            directory: context.directory)
          guard !Task.isCancelled else { return }
          image = loaded
        } catch {
          if !Task.isCancelled { failure = FeedImageFailure.map(error) }
        }
      }
  }
}

struct ToolOutputImages: View {
  @Environment(\.conversationImages) private var context
  let part: ConversationPart
  var messageID: String? = nil
  @State private var loaded: ConversationPart?
  @State private var failed = false
  @State private var textual: [FeedImage] = []
  @State private var attempt = 0
  private var images: [FeedImage] {
    (loaded ?? part).state?.object?["content"]?.array?.compactMap(FeedImage.attachment) ?? []
  }
  private var omitted: Bool {
    part.state?.object?["content"]?.array?.contains {
      ($0.object?["mime"]?.string?.hasPrefix("image/") == true
        || $0.object?["type"]?.string == "image") && FeedImage.attachment($0) == nil
    } == true
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(images.enumerated()), id: \.offset) { _, image in
        FeedImageView(source: image.source, name: image.name)
      }
      ForEach(Array(textual.enumerated()), id: \.offset) { _, image in
        FeedImageView(source: image.source, name: image.name)
      }
      if omitted && images.isEmpty {
        if failed {
          Label("Imagem indisponível no iPhone", systemImage: "photo.badge.exclamationmark")
          Text(part.name ?? "Imagem da ferramenta").font(.caption)
          Button("Tentar novamente") { attempt += 1 }
        } else { ProgressView("Carregando imagem da ferramenta…") }
      }
    }
    .task(id: part.output) {
      let source = part.output
      textual = []
      guard source.contains("![") || source.localizedCaseInsensitiveContains("<img") else { return }
      let parsed = await Task.detached(priority: .utility) {
        MarkdownBlocks.parse(source).compactMap { block -> FeedImage? in
          guard case .image(let source) = block.kind else { return nil }
          return FeedImage(source: source, name: block.text)
        }
      }.value
      if !Task.isCancelled { textual = parsed }
    }
    .task(id: "\(part.id ?? ""):\(context?.directory ?? ""):\(omitted):\(attempt)") {
      guard omitted, let context else { return }
      failed = false
      if part.name == "read", let path = part.input["path"]?.string ?? part.input["filePath"]?.string {
        loaded = ConversationPart(type: "tool", state: .object(["content": .array([
          .object(["type": .string("file"), "mime": .string("image/png"), "uri": .string(path),
            "name": .string(part.state?.object?["content"]?.array?.first {
              $0.object?["mime"]?.string?.hasPrefix("image/") == true
            }?.object?["name"]?.string ?? "Imagem")])
        ])]))
        return
      }
      guard let messageID else { failed = true; return }
      do {
        let message = try await context.client.imageMessage(sessionID: context.sessionID, messageID: messageID)
        guard !Task.isCancelled else { return }
        loaded = message.content?.first { $0.id == part.id }
        failed = images.isEmpty
      } catch { if !Task.isCancelled { failed = true } }
    }
  }
}
