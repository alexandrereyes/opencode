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

  /// The default voice.md, shared with the Watch, says nothing of a screen: each app puts its block first. An edited
  /// prompt from the default until 02/11, with the JSON form, is kept as it is.
  @Test func screenCapabilityGoesAheadOfThePromptUnlessItDocumentsTheScreen() {
    let edited = VoiceProtocol.withScreen("Prompt editado no servidor.", for: .iPhone)
    #expect(edited.hasSuffix("\n\nPrompt editado no servidor."))
    #expect(edited.hasPrefix("Tela do app OpenCode no iPhone: você consegue ver a tela do OpenCode."))
    #expect(edited.contains("gere <|SpawnThinking|>; o app anexa ao") && edited.contains("tá vendo minha tela?"))
    // 02/11: GPT Live delegated "Olha isso aqui" every time, even when told to ask whether to look; the block says what
    // happens then (no capture) and how he can ask for one, never to ask first.
    #expect(edited.contains(#"("olha isso aqui", "o que você acha disso?"), a"# + "\ncaptura não vai;"))
    #expect(edited.contains(#"ver, ele pode pedir "olha minha tela"."#))
    #expect(!edited.contains("pergunte se ele quer"))
    #expect(edited.contains("Nunca diga que não consegue ver a tela sem antes gerar <|SpawnThinking|>."))
    #expect(edited.contains("nunca a de outros apps"))
    // What the route does: no JSON, no priority over the prompt, the agent and never the master, no app by name.
    for platform in [VoiceScreenPlatform.iPhone, .mac] {
      let rules = VoiceProtocol.screenInstructions(platform)
      #expect(!rules.contains("{") && !rules.contains("screen") && !rules.contains("acima de qualquer"))
      #expect(!rules.lowercased().contains("mestra") && !rules.contains("Simulator") && !rules.contains("Chrome"))
      #expect(VoiceProtocol.withScreen(rules + "\n\nPrompt.", for: platform) == rules + "\n\nPrompt.")
    }
    let mac = VoiceProtocol.withScreen("Prompt.", for: .mac)
    #expect(mac.hasPrefix("Tela do Mac: você consegue ver a tela do Mac."))
    #expect(mac.contains(#"ou da tela inteira quando ele diz "a tela toda""#))
    #expect(mac.contains("Gravação de Tela") && !mac.contains("nunca a de outros apps"))
    #expect(VoiceProtocol.withScreen(mac, for: .mac) == mac)
    let former = #"Use {"text":"x","screen":true} para a tela. No Mac, "screen_app":"Nome do app"."#
    #expect(VoiceProtocol.withScreen(former, for: .iPhone) == former)
    #expect(VoiceProtocol.withScreen(former, for: .mac) == former)
    // An iPhone-only form still gets the Mac's block.
    let iPhoneOnly = #"Use {"text":"x","screen":true} para a tela."#
    #expect(VoiceProtocol.withScreen(iPhoneOnly, for: .mac).hasPrefix("Tela do Mac:"))
  }

  @Test(arguments: ["Você está vendo a minha tela aí?", "Tá conseguindo ver minha tela", "cê tá vendo minha tela aí",
    "vê essa tela", "olha a tela do OpenCode", "manda um print pra mestra", "tira um screenshot", "faz uma captura de tela",
    "Olha a minha tela, o que tem aí"])
  func speechAboutTheScreen(_ text: String) {
    #expect(VoiceScreenIntent.target(text) == .front)
  }

  /// The Mac captures the whole screen only for these words; the iPhone captures its own window anyway.
  @Test(arguments: ["Olha minha tela toda", "vê a TELA INTEIRA", "o que tem na minha tela  toda?", "tela inteira do Mac"])
  func speechAboutTheWholeScreen(_ text: String) {
    #expect(VoiceScreenIntent.target(text) == .display)
  }

  /// Pointing at something is not naming the screen: no capture, and the app's block has GPT Live say how to ask for one.
  @Test(arguments: ["Pergunta pra Mestra", "Não, vai lá na Mestra que você consegue", "cria uma sessão no abacato",
    "faz uma costela pro jantar", "liga pro telefone dele", "o que tem de novo?", "vê o que cê acha",
    "Mas dá uma pesquisada na web aí antes de eu falar com o médico, vê o que cê acha em relação a esse tipo de relato",
    "isso aqui é normal?", "o que você acha disso?", "olha aqui, eu acordo às três", "abre a janela do quarto",
    "lê a próxima página", "que erro é esse?", "imprime o relatório", "vê isso pra mim", "olha o simulador",
    "a casa toda", "olha o Chrome inteiro"])
  func speechNotAboutTheScreen(_ text: String) {
    #expect(VoiceScreenIntent.target(text) == nil)
  }
}
