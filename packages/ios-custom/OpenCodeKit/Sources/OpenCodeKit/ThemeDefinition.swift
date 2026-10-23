import Foundation

public enum ThemeRole: Int, CaseIterable, Sendable {
  case background, surface, surfaceRaised, highlight, border, borderStrong, controlBorder
  case textStrong, text, textSecondary, textWeak, icon
  case primary, onPrimary, onInfo, success, info, error, warning, accent
  case filledButton, onFilledButton
  case userBubble, userBubbleText, inlineCode, inlineCodeBackground, codeSurface, toolSurface,
    diffAdd, diffDelete
  case contextTrack, contextFill, contextWarning
  case agentBuild, agentExplore, agentPlan, agentReview, agentWriter, agentExplicit
  case agentPrimary, agentSecondary, agentAccent, agentError, agentStateSuccess, agentStateWarning,
    agentStateInfo
  case agentAsk, agentLegacyBuild, agentDocs, agentLegacyPlan, agentInfo, agentSuccess
  case agentWarning, agentProperty, agentConstant, agentAdded, agentDeleted, agentLegacyWarning
  case composerFile, composerAgent, composerSession, composerSnippet, composerCommand, composerSkill
  case markdownBody, markdownStrong, markdownHeading, markdownQuote, markdownQuoteBorder, markdownLink, markdownRule, markdownTask
  case codeText, codeHeaderText, codeBorder, codeHeaderSeparator, codeGutterSeparator, codeLineNumber
  case tableSurface, tableText, tableHeaderText, tableBorder, tableSeparator
  case syntaxKeyword, syntaxString, syntaxComment, syntaxFunction, syntaxProperty, syntaxType, syntaxConstant, syntaxNumber,
    syntaxVariable, syntaxPunctuation, syntaxOperator, syntaxAdded, syntaxRemoved
  case diagramBackground, diagramText, diagramLine, diagramAccent, diagramMuted, diagramSurface, diagramBorder

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

  public init?(css: String) {
    let value = css.trimmingCharacters(in: .whitespacesAndNewlines)
    let expanded =
      value.hasPrefix("#") && [4, 5].contains(value.count)
      ? "#" + value.dropFirst().map { "\($0)\($0)" }.joined() : value
    if let color = try? ThemeColor(hex: expanded) {
      self = color
      return
    }
    guard let start = value.firstIndex(of: "("), value.last == ")", value.hasPrefix("rgb") else {
      return nil
    }
    let components = value[value.index(after: start)..<value.index(before: value.endIndex)].split(
      separator: ","
    ).map { $0.trimmingCharacters(in: .whitespaces) }
    guard components.count == 3 || components.count == 4 else { return nil }
    let rgb = components.prefix(3).compactMap { component -> Double? in
      if component.hasSuffix("%") { return Double(component.dropLast()).map { $0 / 100 } }
      return Double(component).map { $0 / 255 }
    }
    guard rgb.count == 3, rgb.allSatisfy({ (0...1).contains($0) }),
      let alpha = components.count == 4 ? Double(components[3]) : 1, (0...1).contains(alpha)
    else { return nil }
    red = rgb[0]
    green = rgb[1]
    blue = rgb[2]
    opacity = alpha
  }
}

public struct ThemeDefinition: Decodable, Sendable {
  public let id: String
  public let dark: Bool
  private var colors: [ThemeColor]
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
  public func overriding(_ role: ThemeRole, with color: ThemeColor) -> Self {
    var copy = self
    copy.colors[role.rawValue] = color
    return copy
  }
  public func avatar(_ avatar: ThemeAvatar) -> Avatar { avatars[avatar.rawValue] }
}

public enum ThemeError: Error {
  case missingRole(String)
  case missingAvatar(String)
  case invalidColor(String)
}
