import Foundation
import Observation
import OpenCodeKit

@MainActor @Observable final class ModelCatalogCache {
  private(set) var models: [ModelInfo] = []
  private(set) var recent: [ModelReference]
  private let defaults: UserDefaults
  private let recentKey: String
  init(server: String, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    recentKey = "OpenCodeNewSession." + server + ".recent"
    recent =
      defaults.data(forKey: recentKey).flatMap {
        try? JSONDecoder().decode([ModelReference].self, from: $0)
      } ?? []
  }
  func committed(_ model: ModelReference) {
    recent = ModelPaletteMemory.recording(model, in: recent)
    defaults.set(try? JSONEncoder().encode(recent), forKey: recentKey)
  }
  func remember(_ models: [ModelInfo]) {
    self.models = ModelCatalog.merging(models, fallback: self.models)
  }
}
