import Foundation

public enum ModelCatalog {
  /// Location-specific definitions win; a different provider's identical ID never matches.
  public static func merging(_ primary: [ModelInfo], fallback: [ModelInfo]) -> [ModelInfo] {
    let keys = Set(primary.map { $0.providerID + "\u{0}" + $0.id })
    return primary + fallback.filter { !keys.contains($0.providerID + "\u{0}" + $0.id) }
  }
}

/// One model of a picker, resolved once: its name, its provider's name and its efforts.
public struct ModelChoice: Identifiable, Sendable, Equatable {
  public let modelID: String
  public let providerID: String
  public let name: String
  public let provider: String
  public let variants: [String]
  public var id: String { providerID + "/" + modelID }

  public func reference(variant: String? = nil) -> ModelReference {
    ModelReference(id: modelID, providerID: providerID, variant: variant)
  }

  /// Whether `selected` is this model; with `variant`, also that effort ("default" when none is chosen).
  public func selected(_ selected: ModelReference?, variant: String? = nil) -> Bool {
    guard selected?.id == modelID, selected?.providerID == providerID else { return false }
    return variant.map { (selected?.variant ?? "default") == $0 } ?? true
  }
}

/// The models a picker lists, in the catalog's order, built once per catalog instead of per row and frame:
/// provider names come from one dictionary instead of a search per row.
public enum ModelChoices {
  public static func rows(_ models: [ModelInfo], providers: [ProviderInfo]) -> [ModelChoice] {
    let names = Dictionary(providers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    return models.filter { $0.enabled != false }.map { model in
      ModelChoice(modelID: model.id, providerID: model.providerID, name: model.name,
        provider: names[model.providerID] ?? model.providerID, variants: (model.variants ?? []).map(\.id))
    }
  }
}
