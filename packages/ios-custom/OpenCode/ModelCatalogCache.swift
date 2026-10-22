import Observation
import OpenCodeKit

@MainActor @Observable final class ModelCatalogCache {
  private(set) var models: [ModelInfo] = []
  func remember(_ models: [ModelInfo]) {
    self.models = ModelCatalog.merging(models, fallback: self.models)
  }
}
