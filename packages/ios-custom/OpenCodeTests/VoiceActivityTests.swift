import XCTest
@testable import OpenCode
@testable import OpenCodeKit

@MainActor final class VoiceActivityTests: XCTestCase {
  func testVoiceActivityMappingAndBothThemeVariants() {
    var state = VoiceState()
    state.apply(.start); state.apply(.connected)
    state.masterWorking = true
    state.muted = true
    for variant in ["openchamber-dark", "openchamber-light"] {
      let theme = AppTheme.load(variant)
      let content = VoiceActivityDriver.content(state: state, theme: theme)
      XCTAssertEqual(content.label, "Sessão mestra trabalhando…")
      XCTAssertTrue(content.muted)
      XCTAssertTrue(content.working)
      XCTAssertFalse(content.speaking)
      let color = theme.value(.accent)
      XCTAssertEqual(content.colors[String(ThemeRole.accent.rawValue)], [color.red, color.green, color.blue, color.opacity])
    }
    state.apply(.speech)
    XCTAssertEqual(VoiceActivityDriver.content(state: state, theme: .selected).label, "Falando")
    state.apply(.interruption)
    XCTAssertEqual(VoiceActivityDriver.content(state: state, theme: .selected).label, "Áudio interrompido")
    state.apply(.reconnect)
    let reconnecting = VoiceActivityDriver.content(state: state, theme: .selected)
    XCTAssertEqual(reconnecting.label, "Reconectando…")
    XCTAssertEqual(reconnecting.symbol, "antenna.radiowaves.left.and.right")
    state.apply(.offline)
    let offline = VoiceActivityDriver.content(state: state, theme: .selected)
    XCTAssertEqual(offline.label, "Sem conexão")
    XCTAssertEqual(offline.symbol, "wifi.slash")
  }
  func testStaleSystemActionCannotControlAnotherCall() async {
    VoiceActivityRouter.sessionID = "current"
    var actions = 0
    VoiceActivityRouter.handler = { _ in actions += 1 }
    await VoiceActivityRouter.perform(.end, sessionID: "old")
    XCTAssertEqual(actions, 0)
    await VoiceActivityRouter.perform(.mute, sessionID: "current")
    XCTAssertEqual(actions, 1)
    VoiceActivityRouter.sessionID = nil
    VoiceActivityRouter.handler = nil
  }
}
