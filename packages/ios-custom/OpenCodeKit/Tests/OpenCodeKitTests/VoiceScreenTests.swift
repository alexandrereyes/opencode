import Foundation
import Testing
@testable import OpenCodeKit

struct VoiceScreenTests {
  @Test func capturesOnlyTheUnlockedForegroundApp() {
    #expect(VoiceScreenAccess.refusal(appActive: true, protectedDataAvailable: true) == nil)
    #expect(VoiceScreenAccess.refusal(appActive: false, protectedDataAvailable: true) == .background)
    #expect(VoiceScreenAccess.refusal(appActive: false, protectedDataAvailable: false) == .locked)
    #expect(VoiceScreenAccess.refusal(appActive: true, protectedDataAvailable: false) == .locked)
    let background = VoiceScreenRefusal.background.localizedDescription
    #expect(background.contains("outros apps") && background.contains("Nada foi enviado"))
    #expect(VoiceScreenRefusal.locked.localizedDescription.contains("bloqueado"))
  }

  @Test func contextIsOneLineWithOnlyTheOpenSession() {
    let shot = VoiceScreenShot(jpeg: Data([0xFF, 0xD8]), sessionID: "ses_aberta")
    #expect(shot.prompt("Dá uma olhada nessa tela") ==
      "Dá uma olhada nessa tela\n\n[Captura da tela do app OpenCode anexada. Sessão aberta no app: ses_aberta]")
    #expect(VoiceScreenShot(jpeg: Data(), sessionID: nil).prompt("Veja") == "Veja\n\n[Captura da tela do app OpenCode anexada.]")
  }

  @Test func delegationParsesTheScreenFlag() {
    let plain = VoiceMasterRequest("Confira a sessão")
    #expect(plain.text == "Confira a sessão" && plain.delivery == .steer && !plain.screen)
    let screen = VoiceMasterRequest(#"{"text":"Dá uma olhada nessa tela","screen":true}"#)
    #expect(screen.text == "Dá uma olhada nessa tela" && screen.delivery == .steer && screen.screen)
    let queued = VoiceMasterRequest(#"{"text":"Depois veja","screen":true,"delivery":"queue"}"#)
    #expect(queued.screen && queued.delivery == .queue)
    let bare = VoiceMasterRequest(#"{"screen":true}"#)
    #expect(bare.screen && bare.text == "Dê uma olhada nesta tela do app.")
    let unrelated = VoiceMasterRequest(#"{"foo":1}"#)
    #expect(unrelated.text == #"{"foo":1}"# && !unrelated.screen)
  }

  @Test func screenCapabilitySurvivesAnEditedPrompt() {
    let edited = VoiceProtocol.withScreen("Prompt editado no servidor.")
    #expect(edited.hasPrefix("Prompt editado no servidor.\n\n"))
    #expect(edited.contains(#"{"text":"pedido de Alexandre","screen":true}"#))
    #expect(edited.contains("nunca a de outros apps"))
    let documented = #"Use {"text":"x","screen":true} para a tela."#
    #expect(VoiceProtocol.withScreen(documented) == documented)
  }
}
