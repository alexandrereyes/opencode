import OpenCodeKit
import SwiftUI

/// A resource in its own window. This first version shows the live picture enlarged (snapshots about once a
/// second); the iPhone's interactive viewer (stream, taking control, touches and keyboard) is UIKit and is
/// ported in a later step.
struct MacResourceWindow: View {
  @Environment(\.appTheme) private var theme
  let resourceID: String
  let runtime: MacRuntime
  @State private var resource: SessionResource?
  @State private var image: ResourceImage?
  @State private var taken: Double?
  @State private var failure: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: resource.map { resourceSymbol($0.kind) } ?? "display")
        VStack(alignment: .leading, spacing: 2) {
          Text(resource.map(ContextColumn.title) ?? "Recurso").appFont(.heading, weight: .semibold)
            .foregroundStyle(theme.color(.textStrong))
          Text(resource.map { $0.state.label + (taken.map { " · quadro " + Date(timeIntervalSince1970: $0 / 1000)
            .formatted(date: .omitted, time: .standard) } ?? "") } ?? "Carregando…")
            .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        }
        Spacer()
      }
      .padding(12)
      Divider()
      ZStack {
        theme.color(.background)
        if let image {
          Image(resource: image).resizable().aspectRatio(contentMode: .fit).padding(16)
        } else if let failure {
          Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(theme.color(.error))
        } else {
          ProgressView()
        }
      }
    }
    .frame(minWidth: 320, minHeight: 420)
    .background(theme.color(.background))
    .navigationTitle(resource.map(ContextColumn.title) ?? "Recurso")
    .task(id: resourceID) { await stream() }
  }

  private func stream() async {
    guard let client = runtime.store?.client else { return }
    resource = try? await client.resource(resourceID)
    while !Task.isCancelled {
      do {
        let snapshot = try await client.resourceSnapshot(resourceID, maxWidth: 1200)
        if let data = snapshot.image, let next = ResourceImage(data: data) {
          image = next
          taken = snapshot.takenAt
          failure = nil
        }
      } catch {
        if image == nil { failure = "Sem imagem do recurso agora." }
      }
      try? await Task.sleep(for: .seconds(1))
      if Int(Date.now.timeIntervalSince1970) % 10 == 0 { resource = (try? await client.resource(resourceID)) ?? resource }
    }
  }
}
