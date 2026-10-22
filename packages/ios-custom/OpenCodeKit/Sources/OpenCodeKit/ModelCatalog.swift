import Foundation

public enum ModelCatalog {
  /// Location-specific definitions win; a different provider's identical ID never matches.
  public static func merging(_ primary: [ModelInfo], fallback: [ModelInfo]) -> [ModelInfo] {
    let keys = Set(primary.map { $0.providerID + "\u{0}" + $0.id })
    return primary + fallback.filter { !keys.contains($0.providerID + "\u{0}" + $0.id) }
  }
}
