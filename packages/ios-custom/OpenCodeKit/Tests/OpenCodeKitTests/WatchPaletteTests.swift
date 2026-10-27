import Foundation
import Testing

@testable import OpenCodeKit

@Suite struct WatchPaletteTests {
  @Test func matchesOpenChamberDark() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "OpenCode/Resources/Themes/openchamber-dark.json")
    struct Theme: Decodable { let colors: [String: String] }
    let theme = try JSONDecoder().decode(Theme.self, from: Data(contentsOf: url))
    for (role, hex) in WatchPalette.hex {
      #expect(theme.colors[role.name]?.lowercased() == hex, "\(role.name)")
    }
  }
}
