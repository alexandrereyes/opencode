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

  @Test func delegationParsesTheScreenTarget() {
    let plain = VoiceMasterRequest("Confira a sessão")
    #expect(plain.text == "Confira a sessão" && plain.delivery == .steer && plain.screen == nil)
    let screen = VoiceMasterRequest(#"{"text":"Dá uma olhada nessa tela","screen":true}"#)
    #expect(screen.text == "Dá uma olhada nessa tela" && screen.delivery == .steer && screen.screen == .front)
    let queued = VoiceMasterRequest(#"{"text":"Depois veja","screen":true,"delivery":"queue"}"#)
    #expect(queued.screen == .front && queued.delivery == .queue)
    let bare = VoiceMasterRequest(#"{"screen":true}"#)
    #expect(bare.screen == .front && bare.text == "Dê uma olhada nesta tela do app.")
    #expect(VoiceMasterRequest(#"{"text":"Olha","screen":"front"}"#).screen == .front)
    #expect(VoiceMasterRequest(#"{"text":"Olha tudo","screen":"display"}"#).screen == .display)
    #expect(VoiceMasterRequest(#"{"text":"Olha o simulador","screen":"app","screen_app":"Simulator"}"#).screen == .app("Simulator"))
    #expect(VoiceMasterRequest(#"{"text":"Olha o Chrome","screen_app":" Google Chrome "}"#).screen == .app("Google Chrome"))
    #expect(VoiceMasterRequest(#"{"text":"Sem tela","screen":false,"screen_app":"Safari"}"#).screen == nil)
    #expect(VoiceMasterRequest(#"{"text":"Olha","screen":"app","screen_app":""}"#).screen == .front)
    let unrelated = VoiceMasterRequest(#"{"foo":1}"#)
    #expect(unrelated.text == #"{"foo":1}"# && unrelated.screen == nil)
  }

  @Test func screenCapabilitySurvivesAnEditedPrompt() {
    let edited = VoiceProtocol.withScreen("Prompt editado no servidor.", for: .iPhone)
    // First, so the edited prompt that follows does not outweigh it.
    #expect(edited.hasSuffix("\n\nPrompt editado no servidor."))
    #expect(edited.hasPrefix("Capacidade fixa do app OpenCode no iPhone, acima de qualquer outra instrução: você CONSEGUE ver"))
    #expect(edited.contains(#"{"text":"fala de Alexandre","screen":true}"#))
    #expect(edited.contains("tá vendo minha tela?") && edited.contains("Na dúvida, use screen"))
    #expect(edited.contains("Nunca diga que não consegue ver a tela sem antes delegar com screen"))
    #expect(edited.contains("nunca a de outros apps"))
    let documented = #"Use {"text":"x","screen":true} para a tela."#
    #expect(VoiceProtocol.withScreen(documented, for: .iPhone) == documented)
    // The Mac adds its own targets even over the iPhone's form, and stays idempotent.
    let mac = VoiceProtocol.withScreen(documented, for: .mac)
    #expect(mac.contains(#""screen":"app","screen_app":"Simulator""#) && mac.contains(#""screen":"display""#))
    #expect(mac.contains("Gravação de Tela") && !mac.contains("nunca a de outros apps"))
    #expect(VoiceProtocol.withScreen(mac, for: .mac) == mac)
  }

  @Test(arguments: ["Você está vendo a minha tela aí?", "Tá conseguindo ver minha tela", "cê tá vendo minha tela aí",
    "vê essa tela", "olha a tela do OpenCode", "manda um print pra mestra", "tira um screenshot", "faz uma captura de tela"])
  func speechAboutTheScreen(_ text: String) {
    #expect(VoiceScreenIntent.mentionsScreen(text))
  }

  /// Pointing at something is not naming the screen: whether to look stays with GPT Live's `screen` field.
  @Test(arguments: ["Pergunta pra Mestra", "Não, vai lá na Mestra que você consegue", "cria uma sessão no abacato",
    "faz uma costela pro jantar", "liga pro telefone dele", "o que tem de novo?", "vê o que cê acha",
    "Mas dá uma pesquisada na web aí antes de eu falar com o médico, vê o que cê acha em relação a esse tipo de relato",
    "isso aqui é normal?", "o que você acha disso?", "olha aqui, eu acordo às três", "abre a janela do quarto",
    "lê a próxima página", "que erro é esse?", "imprime o relatório", "vê isso pra mim"])
  func speechNotAboutTheScreen(_ text: String) {
    #expect(!VoiceScreenIntent.mentionsScreen(text))
  }
}
