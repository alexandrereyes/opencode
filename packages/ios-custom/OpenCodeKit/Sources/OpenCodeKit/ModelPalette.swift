import Foundation

/// The Mac palette's local projection. Visibility remains the shared iPhone preference contract.
public enum ModelPalette {
  public struct Row: Identifiable, Sendable {
    public let model: ModelInfo
    public let group: String
    public let favorite: Bool
    public let matches: [Range<String.Index>]
    public var id: String { model.identity }
  }

  public static func rows(models: [ModelInfo], preferences: Preferences.Models?, providers: [ProviderInfo],
    favorites: Set<String>, recent: [ModelReference], query: String) -> [Row] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let recent = recent.map { $0.providerID + "/" + $0.id }
    let names = Dictionary(providers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    return ConversationProjection.visibleModels(models, preferences: preferences).compactMap { model -> (Row, Int)? in
      let matches = matches(model.name, query: query)
      let rank: Int
      if query.isEmpty { rank = 0 }
      else if let first = matches.first {
        rank = first.lowerBound == model.name.startIndex ? 0
          : !model.name[model.name.index(before: first.lowerBound)].isLetter ? 1 : 2
      } else if (model.id + " " + (names[model.providerID] ?? model.providerID))
        .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { rank = 3 }
      else { return nil }
      let group = favorites.contains(model.identity) ? "Favoritos"
        : recent.contains(model.identity) ? "Recentes" : names[model.providerID] ?? model.providerID
      return (Row(model: model, group: group, favorite: favorites.contains(model.identity), matches: matches), rank)
    }.sorted { a, b in
      if a.1 != b.1 { return a.1 < b.1 }
      if a.0.favorite != b.0.favorite { return a.0.favorite }
      let left = recent.firstIndex(of: a.0.id) ?? .max
      let right = recent.firstIndex(of: b.0.id) ?? .max
      if !a.0.favorite, left != right { return left < right }
      let first = a.0.group + " " + a.0.model.name + " " + a.0.id
      let second = b.0.group + " " + b.0.model.name + " " + b.0.id
      return first.localizedStandardCompare(second) == .orderedAscending
    }.map(\.0)
  }

  public static func matches(_ name: String, query: String) -> [Range<String.Index>] {
    guard !query.isEmpty else { return [] }
    var result: [Range<String.Index>] = []
    var start = name.startIndex
    while start < name.endIndex,
      let range = name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<name.endIndex) {
      result.append(range)
      start = range.upperBound
    }
    return result
  }

  /// Keep Padrão: it means server default, and is distinct from an explicit `none` variant.
  public static func efforts(_ model: ModelInfo) -> [String] {
    let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    return ["default"] + Array(Set((model.variants ?? []).map(\.id))).filter { $0 != "default" }.sorted {
      let a = order.firstIndex(of: $0) ?? .max
      let b = order.firstIndex(of: $1) ?? .max
      return a == b ? $0 < $1 : a < b
    }
  }

  public static func effort(_ model: ModelInfo, current: ModelReference?, saved: String?) -> String {
    let value = current?.id == model.id && current?.providerID == model.providerID ? current?.variant : saved
    return value.flatMap { efforts(model).contains($0) ? $0 : nil } ?? "default"
  }

  public static func label(_ effort: String) -> String {
    ["default": "Padrão", "none": "none", "minimal": "MIN", "low": "L", "medium": "M", "high": "H",
      "xhigh": "XH", "max": "MAX"][effort] ?? effort.uppercased()
  }
}

/// Per-server recent choices, using the existing catalog cache's key and encoding.
/// Favorites already belong to `Preferences.Models` and `modelFavorite`, shared with iOS and the web.
@MainActor public final class ModelPaletteMemory {
  private let defaults: UserDefaults
  private let prefix: String
  public init(server: String, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    prefix = "OpenCodeNewSession." + server
  }
  public var recent: [ModelReference] {
    defaults.data(forKey: prefix + ".recent").flatMap { try? JSONDecoder().decode([ModelReference].self, from: $0) } ?? []
  }
  public func used(_ model: ModelReference) {
    let values = Self.recording(model, in: recent)
    defaults.set(try? JSONEncoder().encode(values), forKey: prefix + ".recent")
  }
  public static func recording(_ model: ModelReference, in recent: [ModelReference]) -> [ModelReference] {
    Array(([ModelReference(id: model.id, providerID: model.providerID)]
      + recent.filter { $0.id != model.id || $0.providerID != model.providerID }).prefix(10))
  }
}
