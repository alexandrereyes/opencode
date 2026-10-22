import Foundation

public struct ThemeVariant: Decodable, Sendable {
  public let id: String
  public let name: String
  public let dark: Bool
}

public struct ThemeFamily: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let light: String
  public let dark: String

  public static func registry(_ data: Data) throws -> [Self] {
    let variants = try JSONDecoder().decode([ThemeVariant].self, from: data)
    return variants.filter(\.dark).compactMap { variant in
      let id = String(variant.id.dropLast("-dark".count))
      guard let light = variants.first(where: { $0.id == id + "-light" && !$0.dark }) else {
        return nil
      }
      return Self(id: id, name: variant.name, light: light.id, dark: variant.id)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}

public enum ThemeAppearance: String, CaseIterable, Codable, Sendable {
  case system, light, dark
  public var title: String {
    switch self {
    case .system: "Sistema"
    case .light: "Claro"
    case .dark: "Escuro"
    }
  }
}

public struct ThemeSelection: Sendable {
  public let family: String
  public let appearance: ThemeAppearance
  public let override: String?

  public init(family: String?, appearance: String?, arguments: [String]) {
    self.family = family ?? "openchamber"
    self.appearance = appearance.flatMap(ThemeAppearance.init(rawValue:)) ?? .system
    override = arguments.firstIndex(of: "-OpenCodeTheme").flatMap {
      arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
    }
  }

  public func resolve(systemDark: Bool) -> String {
    override ?? family + ((appearance == .dark || (appearance == .system && systemDark)) ? "-dark" : "-light")
  }
}
