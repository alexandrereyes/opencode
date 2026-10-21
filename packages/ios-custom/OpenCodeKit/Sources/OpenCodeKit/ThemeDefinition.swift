import Foundation

public enum ThemeRole: Int, CaseIterable, Sendable {
  case background, surface, surfaceRaised, highlight, border
  case textStrong, text, textSecondary, textWeak, icon
  case primary, onPrimary, onInfo, success, info, error, warning, accent
  case filledButton, onFilledButton

  public var name: String { String(describing: self) }
}

public enum ThemeAvatar: Int, CaseIterable, Sendable {
  case lime, orange, purple, cyan, pink, mint
  public var name: String { String(describing: self) }
}

public struct ThemeColor: Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let opacity: Double

  init(hex: String) throws {
    guard hex.first == "#", [7, 9].contains(hex.count),
      let value = UInt64(hex.dropFirst(), radix: 16)
    else {
      throw ThemeError.invalidColor(hex)
    }
    let alpha = hex.count == 9
    red = Double((value >> (alpha ? 24 : 16)) & 255) / 255
    green = Double((value >> (alpha ? 16 : 8)) & 255) / 255
    blue = Double((value >> (alpha ? 8 : 0)) & 255) / 255
    opacity = alpha ? Double(value & 255) / 255 : 1
  }
}

public struct ThemeDefinition: Decodable, Sendable {
  public let id: String
  public let dark: Bool
  private let colors: [ThemeColor]
  private let avatars: [Avatar]

  public struct Avatar: Sendable {
    public let background: ThemeColor
    public let text: ThemeColor
  }

  public init(from decoder: any Decoder) throws {
    struct Source: Decodable {
      let id: String
      let dark: Bool
      let colors: [String: String]
      let avatars: [String: AvatarSource]
      struct AvatarSource: Decodable {
        let background: String
        let text: String
      }
    }
    let source = try Source(from: decoder)
    id = source.id
    dark = source.dark
    colors = try ThemeRole.allCases.map { role in
      guard let hex = source.colors[role.name] else { throw ThemeError.missingRole(role.name) }
      return try ThemeColor(hex: hex)
    }
    avatars = try ThemeAvatar.allCases.map { avatar in
      guard let value = source.avatars[avatar.name] else {
        throw ThemeError.missingAvatar(avatar.name)
      }
      return try Avatar(
        background: ThemeColor(hex: value.background), text: ThemeColor(hex: value.text))
    }
  }

  public func color(_ role: ThemeRole) -> ThemeColor { colors[role.rawValue] }
  public func avatar(_ avatar: ThemeAvatar) -> Avatar { avatars[avatar.rawValue] }
}

public enum ThemeError: Error {
  case missingRole(String)
  case missingAvatar(String)
  case invalidColor(String)
}
