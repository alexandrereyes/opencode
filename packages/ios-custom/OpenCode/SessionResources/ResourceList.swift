import Observation
import OpenCodeKit
import SwiftUI

/// Opens `opencode-resource:` links from anywhere (response text, tool details) in the full-screen viewer.
@MainActor enum ResourceLinks {
  static weak var store: SessionStore?
  static func open(_ id: String) {
    guard let store else { return }
    Task {
      do {
        store.openResource = try await store.client.resource(id)
      } catch {
        store.toast.show("Recurso indisponível", kind: .error)
      }
    }
  }
}

/// Thumbnails for the resource rows, refreshed by snapshot while the list is visible.
@MainActor @Observable final class ResourceThumbnails {
  private(set) var images: [String: UIImage] = [:]
  @ObservationIgnored private var taken: [String: Date] = [:]
  /// Running resources refresh about every 5 seconds; stopped ones keep their last image.
  func refresh(_ resources: [SessionResource], client: OpenCodeClient) async {
    for resource in resources where resource.state.running || images[resource.id] == nil {
      if Task.isCancelled { return }
      if let last = taken[resource.id], Date.now.timeIntervalSince(last) < 4 { continue }
      taken[resource.id] = .now
      guard let snapshot = try? await client.resourceSnapshot(resource.id, maxWidth: 240), let data = snapshot.image
      else { continue }
      let image = await Task.detached { UIImage(data: data)?.preparingForDisplay() }.value
      if let image { images[resource.id] = image }
    }
  }
  func run(_ resources: @escaping @MainActor () -> [SessionResource], client: OpenCodeClient) async {
    while !Task.isCancelled {
      await refresh(resources(), client: client)
      try? await Task.sleep(for: .seconds(5))
    }
  }
}

/// One resource in "Agentes e tarefas" (layout 1B): live thumbnail, kind, name and state.
struct ResourceRow: View {
  @Environment(\.appTheme) private var theme
  let resource: SessionResource
  let image: UIImage?
  var via: String? = nil
  let open: () -> Void
  var body: some View {
    Button(action: open) {
      HStack(spacing: 12) {
        thumbnail
        VStack(alignment: .leading, spacing: 3) {
          Text(resource.kind.title).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
          Text(resource.label).appFont(.secondary, weight: .semibold).foregroundStyle(theme.color(.textStrong))
            .lineLimit(2)
          state
        }
        Spacer(minLength: 3)
        Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.icon))
      }
      .padding(.vertical, 4).contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityValue(resource.state.label)
    .accessibilityIdentifier("resource-row-" + resource.id)
  }

  private var portrait: Bool { resource.kind != .chrome }

  private var thumbnail: some View {
    let radius: CGFloat = portrait ? 8 : 6
    let shape = RoundedRectangle(cornerRadius: radius)
    return shape.fill(theme.color(.surfaceRaised))
      .frame(width: portrait ? 40 : 64, height: portrait ? 76 : 44)
      .overlay {
        if let image {
          Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
          Image(systemName: symbol).appSymbol(.action).foregroundStyle(theme.color(.textWeak))
        }
      }
      .clipShape(shape)
      .overlay { shape.strokeBorder(theme.color(.border), lineWidth: 1) }
      .overlay(alignment: .top) {
        if [.agent, .live, .user].contains(resource.state) {
          Text("AO VIVO").font(.system(size: 7, weight: .bold)).foregroundStyle(.white).fixedSize()
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(theme.color(.error), in: .capsule).padding(.top, 3)
        }
      }
      .opacity(resource.state.running ? 1 : 0.55)
      .frame(width: 64)
      .accessibilityHidden(true)
  }

  private var symbol: String {
    switch resource.kind {
    case .iosSimulator: "iphone"
    case .androidEmulator: "candybarphone"
    case .chrome: "globe"
    case .unknown: "display"
    }
  }

  private var state: some View {
    HStack(spacing: 5) {
      switch resource.state {
      case .user: Circle().fill(theme.color(.primary)).frame(width: 7, height: 7)
      case .agent, .live: Circle().fill(theme.color(.success)).frame(width: 7, height: 7)
      case .idle: Circle().strokeBorder(theme.color(.textSecondary), lineWidth: 1.2).frame(width: 8, height: 8)
      case .stopped, .gone: Image(systemName: "minus.circle.fill").foregroundStyle(theme.color(.textWeak))
      }
      Text(resource.state.label)
        .foregroundStyle(theme.color(resource.state == .live ? .success : .textSecondary))
      if let via { Text("· via \(via)").foregroundStyle(theme.color(.textSecondary)).lineLimit(1) }
    }
    .appFont(.caption)
  }
}
