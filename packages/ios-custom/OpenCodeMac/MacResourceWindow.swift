import OpenCodeKit
import SwiftUI

/// A resource in its own window: the iPhone's interactive viewer (`ResourceViewerScreen`, one view per kind) with
/// the live stream, the status pill, Assumir controle / Devolver and the kind's tools. In control a click is a
/// touch, a drag moves it, the trackpad scrolls, and the Mac's keyboard types into the resource (⌘V pastes).
/// Closing the window gives control back, like closing the iPhone's viewer.
struct MacResourceWindow: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismissWindow) private var dismissWindow
  let resourceID: String
  let runtime: MacRuntime
  @State private var resource: SessionResource?
  @State private var failure: String?

  var body: some View {
    Group {
      if let resource, let client = runtime.store?.client {
        ResourceViewerScreen(resource: resource, client: client) {
          dismissWindow(id: "resource", value: resourceID)
        }
      } else if let failure {
        ContentUnavailableView {
          Label("Recurso indisponível", systemImage: "exclamationmark.triangle")
        } description: { Text(failure) } actions: {
          Button("Tentar novamente") { Task { await load() } }
        }
      } else {
        ProgressView()
      }
    }
    .frame(minWidth: 360, minHeight: 520)
    .background(theme.color(.background))
    .navigationTitle(resource.map(ContextColumn.title) ?? "Recurso")
    .task(id: resourceID) { await load() }
  }

  private func load() async {
    guard let client = runtime.store?.client else { return }
    do {
      resource = try await client.resource(resourceID)
      failure = nil
    } catch {
      failure = error.localizedDescription
    }
  }
}
