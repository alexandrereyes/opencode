import Foundation
import Observation
import OpenCodeKit

/// App mentions shared by every composer. Listing starts as soon as a composer knows its enabled app
/// MCPs, outside the typing path; `revision` tells an open suggestion panel that a listing arrived.
@MainActor @Observable final class ComposerAppMentions {
  static let shared = ComposerAppMentions()
  private(set) var revision = 0
  @ObservationIgnored private var cache = ComposerAppCache()

  func apps(_ scope: ComposerAppScope) -> [ComposerApp] { cache.apps(scope) }

  func prepare(_ scope: ComposerAppScope, client: OpenCodeClient, open: Bool) {
    guard cache.begin(scope, open: open) else { return }
    Task {
      let apps = try? await client.composerApps(scope)
      cache.finish(scope, apps: apps)
      revision += 1
    }
  }
}
