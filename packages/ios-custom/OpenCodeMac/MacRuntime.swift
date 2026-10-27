import Observation
import OpenCodeKit
import SwiftUI

/// App-wide state of the Mac app: the server, the appearance, the Sessões store and what the window shows.
@MainActor @Observable final class MacRuntime {
  static let shared = MacRuntime()
  /// The Mac app talks to this Mac's own server by default; Configurações can point it elsewhere.
  static let localURL = URL(string: "http://127.0.0.1:4096")!

  let servers = ServerStore(launchOverride: .override(), builtinURL: MacRuntime.localURL)
  let appearance = AppearanceSettings()
  var store: SessionStore?
  var identity = UUID()
  var appliedRevision = -1
  var error: String?
  /// The third column (Contexto) is an inspector that can be hidden.
  var contextVisible = true
  var selection = MacSelection()
  @ObservationIgnored private var building: Task<Void, Never>?

  func prepare() async {
    if let building { await building.value }
    guard store == nil || appliedRevision != servers.revision else { return }
    let task = Task { await rebuild() }
    building = task
    await task.value
    building = nil
  }

  private func rebuild() async {
    await store?.stop()
    do {
      #if DEBUG
      if let fixture = MacFixture.current {
        store = SessionStore(configuration: MacFixture.configuration, acceptsLaunchSession: false,
          client: fixture.client())
        selection = fixture.selection
        appliedRevision = servers.revision
        identity = UUID()
        return
      }
      #endif
      store = SessionStore(configuration: try servers.configuration(), acceptsLaunchSession: false)
      selection = MacSelection()
      appliedRevision = servers.revision
      identity = UUID()
      error = nil
    } catch {
      store = nil
      self.error = error.localizedDescription
    }
  }

  func showFiles(at path: String? = nil, file: String? = nil) {
    contextVisible = true
    selection.files = MacSelection.Files(folder: path, file: file)
  }
}

/// What the window shows: the selected root session, a subagent opened from Contexto in the middle column,
/// and the Arquivos view over the Contexto column.
struct MacSelection: Equatable {
  struct Files: Equatable {
    /// The folder shown; nil opens the session's checkout root.
    var folder: String?
    /// The file selected in the list and shown below it.
    var file: String?
  }
  var sessionID: String?
  /// A subagent of `sessionID` opened in the middle column.
  var childID: String?
  var files: Files?
}
