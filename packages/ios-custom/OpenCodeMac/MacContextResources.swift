import AppKit
import OpenCodeKit
import SwiftUI

/// `RECURSOS N` with live previews, in the column's sober style: what an agent (or Alexandre) is using shows as
/// large thumbnails with a thin outline, refreshed by snapshot like the iPhone's rows (`ResourceThumbnails`, about
/// every 5 s); free and stopped resources are compact rows with a small thumbnail. A click opens the resource's
/// window; hovering shows Abrir, Captura and Encerrar. Snapshots stop while the section is off screen (Contexto
/// hidden, Arquivos over it, another session) and while the window is minimized or fully covered.
struct MacResourcesSection: View {
  @Environment(\.openWindow) private var openWindow
  let store: ContextColumnStore
  let runtime: MacWindowRuntime
  @State private var thumbnails = ResourceThumbnails(width: 640)
  #if DEBUG
  /// `-OpenCodeMacResourceProfile visible`: refresh as if on screen, to measure the previews' cost off-screen.
  static let profiling = ["visible", "frozen"].contains(MacFixture.value("-OpenCodeMacResourceProfile"))
  /// `frozen`: the first pictures only, the baseline of that measurement.
  static let frozen = MacFixture.value("-OpenCodeMacResourceProfile") == "frozen"
  #else
  static let profiling = false
  static let frozen = false
  #endif

  var body: some View {
    let split = ContextColumn.resources(store.resources)
    VStack(alignment: .leading, spacing: 0) {
      ContextSectionLabel(title: "Recursos", count: "\(split.inUse.count + split.others.count)").padding(.bottom, 8)
      if !split.inUse.isEmpty {
        // One resource takes the whole width (the stage); more share two columns.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
          count: split.inUse.count == 1 ? 1 : 2), alignment: .leading, spacing: 14) {
          ForEach(split.inUse) { resource in
            MacResourceTile(resource: resource, image: thumbnails.images[resource.id], user: user(resource),
              large: split.inUse.count == 1, actions: actions(resource))
          }
        }
        .padding(.bottom, split.others.isEmpty ? 4 : 10)
      }
      ForEach(Array(split.others.enumerated()), id: \.element.id) { index, resource in
        if index > 0 || !split.inUse.isEmpty { ContextHairline() }
        MacResourceLine(resource: resource, image: thumbnails.images[resource.id], actions: actions(resource))
      }
    }
    #if DEBUG
    .task {
      // `-OpenCodeMacResourceProfile minimized`: the window goes to the Dock, where snapshots must stop.
      guard MacFixture.value("-OpenCodeMacResourceProfile") == "minimized" else { return }
      try? await Task.sleep(for: .seconds(3))
      runtime.window?.miniaturize(nil)
    }
    #endif
    .task(id: store.resources.map(\.id)) {
      await thumbnails.run({ [runtime, thumbnails] in
        // A minimized or fully covered window draws nothing: no snapshot until it shows again.
        guard let window = runtime.window, window.occlusionState.contains(.visible) || Self.profiling,
          !window.isMiniaturized else { return [] }
        // Tiles in use follow the resource; a free or stopped one keeps its first small picture.
        return store.resources.filter {
          (ContextColumn.inUse($0) && !Self.frozen) || thumbnails.images[$0.id] == nil
        }
      }, client: store.client)
    }
  }

  /// The subagent driving a resource, by its title.
  private func user(_ resource: SessionResource) -> String? {
    ContextColumn.user(of: resource, rootID: store.id, members: store.members).flatMap(store.title)
  }

  private func actions(_ resource: SessionResource) -> MacResourceActions {
    MacResourceActions(
      open: { openWindow(id: "resource", value: resource.id) },
      capture: { MacResourceCapture.save(resource, client: store.client, toast: store.sessions.toast) },
      close: { Task { await store.dismiss(resource) } })
  }
}

struct MacResourceActions {
  let open: () -> Void
  let capture: () -> Void
  /// The server stops nothing on its own: Encerrar takes the resource off the lists (it comes back when an agent
  /// uses it again).
  let close: () -> Void
}

/// A resource in use: the live thumbnail with a thin outline, then `Simulador iOS · iPhone 17 Pro` and
/// `Agente usando · <subagent>` in small gray.
private struct MacResourceTile: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  let resource: SessionResource
  let image: ResourceImage?
  let user: String?
  let large: Bool
  let actions: MacResourceActions
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: actions.open) {
        RoundedRectangle(cornerRadius: 8).fill(theme.color(.surface))
          .overlay {
            if let image {
              Image(resource: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
              Image(systemName: resourceSymbol(resource.kind)).font(.system(size: 22))
                .foregroundStyle(theme.color(.textWeak))
            }
          }
          .frame(height: large ? 220 : 150)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.textSecondary).opacity(0.55), lineWidth: 1)
          }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .overlay(alignment: .topTrailing) { if hovering { MacResourceHoverActions(actions: actions).padding(6) } }
      VStack(alignment: .leading, spacing: 2) {
        Text(ContextColumn.title(resource)).foregroundStyle(theme.color(.text))
        Text([resource.state.label, user].compactMap { $0 }.joined(separator: " · "))
          .foregroundStyle(theme.color(.textSecondary))
      }
      .appFont(.caption).lineLimit(1).truncationMode(.middle)
    }
    .onHover { hovering = $0 }
    .help("Abrir \(ContextColumn.title(resource))")
    .contextMenu { MacResourceMenu(resource: resource, actions: actions) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(ContextColumn.title(resource)), \(resource.state.label)")
    .accessibilityIdentifier("resource-tile-" + resource.id)
  }
}

/// A free or stopped resource: a small thumbnail, its name and its state.
private struct MacResourceLine: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  let resource: SessionResource
  let image: ResourceImage?
  let actions: MacResourceActions
  @State private var hovering = false

  var body: some View {
    Button(action: actions.open) {
      HStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 4).fill(theme.color(.surface))
          .overlay {
            if let image {
              Image(resource: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
              Image(systemName: resourceSymbol(resource.kind)).font(.system(size: 11))
                .foregroundStyle(theme.color(.icon))
            }
          }
          .frame(width: resource.kind == .chrome ? 44 : 22, height: 30)
          .clipShape(RoundedRectangle(cornerRadius: 4))
          .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(theme.color(.border), lineWidth: 1 / 2) }
          .opacity(resource.state.running ? 1 : 0.6)
          .accessibilityHidden(true)
        Text(ContextColumn.title(resource)).appFont(.caption)
          .foregroundStyle(theme.color(resource.state.running ? .text : .textSecondary))
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
        if hovering {
          MacResourceHoverActions(actions: actions)
        } else {
          Text(state).appFont(.caption).monospacedDigit().foregroundStyle(theme.color(.textSecondary))
            .lineLimit(1).fixedSize()
        }
      }
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("Abrir \(ContextColumn.title(resource))")
    .contextMenu { MacResourceMenu(resource: resource, actions: actions) }
    .accessibilityIdentifier("resource-line-" + resource.id)
  }

  /// "Livre", "Parado há 8 min".
  private var state: String {
    guard !resource.state.running else { return resource.state.label }
    let at = resource.updatedAt > 0 ? resource.updatedAt : resource.lastUsedAt
    return at > 0 ? "Parado " + ContextColumn.ago(at, now: now) : "Parado"
  }
}

/// Abrir · Captura · Encerrar, shown while the pointer is over a resource.
private struct MacResourceHoverActions: View {
  @Environment(\.appTheme) private var theme
  let actions: MacResourceActions
  var body: some View {
    HStack(spacing: 2) {
      button("macwindow", "Abrir", actions.open)
      button("camera", "Captura", actions.capture)
      button("xmark.circle", "Encerrar", actions.close)
    }
    .padding(2)
    .background(theme.color(.background).opacity(0.85), in: Capsule())
    .overlay { Capsule().strokeBorder(theme.color(.border), lineWidth: 0.5) }
  }

  private func button(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.color(.text))
        .frame(width: 22, height: 20).contentShape(Rectangle())
    }
    .buttonStyle(.plain).help(title == "Encerrar" ? "Encerrar (tira da lista; volta se um agente usar de novo)" : title)
    .accessibilityLabel(title)
  }
}

private struct MacResourceMenu: View {
  let resource: SessionResource
  let actions: MacResourceActions
  var body: some View {
    Button("Abrir", systemImage: "macwindow", action: actions.open)
    Button("Salvar captura…", systemImage: "camera", action: actions.capture)
    Divider()
    Button("Encerrar", systemImage: "xmark.circle", role: .destructive, action: actions.close)
  }
}

/// Captura: the resource's current frame at full size, saved where Alexandre chooses.
@MainActor enum MacResourceCapture {
  static func save(_ resource: SessionResource, client: OpenCodeClient, toast: ToastCenter) {
    Task {
      do {
        let snapshot = try await client.resourceSnapshot(resource.id)
        guard let data = snapshot.image else { throw ClientError.http(404) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ContextColumn.name(resource) + ".png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        try png.write(to: url)
      } catch {
        toast.show("Não foi possível capturar o recurso.", kind: .error)
      }
    }
  }
}
