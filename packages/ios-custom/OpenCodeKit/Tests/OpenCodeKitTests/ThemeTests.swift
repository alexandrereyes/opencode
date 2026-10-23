import Foundation
import Testing

@testable import OpenCodeKit

private func themeSource() -> [String: JSONValue] {
  [
    "id": .string("test"), "dark": .bool(true),
    "colors": .object(
      Dictionary(uniqueKeysWithValues: ThemeRole.allCases.map { ($0.name, .string("#123456")) })),
    "avatars": .object(
      Dictionary(
        uniqueKeysWithValues: ThemeAvatar.allCases.map {
          ($0.name, .object(["background": .string("#345678"), "text": .string("#abcdef")]))
        })),
  ]
}

@Test func themesRequireEveryTypedRoleAndAvatar() throws {
  let source = themeSource()
  let theme = try JSONDecoder().decode(ThemeDefinition.self, from: JSONEncoder().encode(source))
  #expect(theme.color(.background).red == Double(0x12) / 255)
  #expect(theme.avatar(.lime).text.blue == Double(0xef) / 255)
  for role in ThemeRole.allCases {
    var missing = source
    var colors = source["colors"]!.object!
    colors.removeValue(forKey: role.name)
    missing["colors"] = .object(colors)
    let data = try JSONEncoder().encode(missing)
    #expect(throws: ThemeError.self) { try JSONDecoder().decode(ThemeDefinition.self, from: data) }
  }
  for avatar in ThemeAvatar.allCases {
    var missing = source
    var avatars = source["avatars"]!.object!
    avatars.removeValue(forKey: avatar.name)
    missing["avatars"] = .object(avatars)
    let data = try JSONEncoder().encode(missing)
    #expect(throws: ThemeError.self) { try JSONDecoder().decode(ThemeDefinition.self, from: data) }
  }
}

@Test func themeColorsValidateRGBAndRGBA() throws {
  #expect(try ThemeColor(hex: "#12345680").opacity == Double(0x80) / 255)
  #expect(throws: ThemeError.self) { try ThemeColor(hex: "not a color") }
  #expect(throws: ThemeError.self) { try ThemeColor(hex: "#xyzxyz") }
}

@Test func bundledThemeVariantsContainAllSemanticRoles() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("OpenCode/Resources/Themes")
  let variants = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" && $0.lastPathComponent != "registry.json" }
  #expect(variants.count == 76)
  for variant in variants {
    let theme = try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: variant))
    #expect(!theme.id.isEmpty)
  }
}
