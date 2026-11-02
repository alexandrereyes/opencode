import Foundation
import Testing
@testable import OpenCodeKit

struct VoiceRequestTests {
  private func turn(_ id: String?, _ role: VoiceMemoryTurn.Role, _ text: String) -> VoiceCompletedTurn {
    VoiceCompletedTurn(id: id, itemID: nil, role: role, text: text, interrupted: false)
  }

  /// Validation of 02/11: the delegation's text is the turn's transcript, and that turn's `turn.done` comes after it.
  @Test func theRequestIsTheSpeechPlusTheConversationSinceThePreviousOne() {
    var context = VoiceRequestContext()
    #expect(context.request(" Quantas sessões estão abertas?", turn: "t1") == "Quantas sessões estão abertas?",
      "nothing else was said: no block")
    context.heard(turn("t1", .user, " Quantas sessões estão abertas?"))
    context.heard(turn("a1", .assistant, " Vou verificar."))
    context.heard(turn("a2", .assistant, "Há duas: Abacato e Misty."))
    context.heard(turn("a2", .assistant, "Repetido"))
    context.heard(turn("a3", .assistant, "   "))
    #expect(context.request("E a outra?", turn: "t2") == """
      E a outra?

      Conversa por voz desde o pedido anterior (transcrição, pode ter erros):
      Voz: Vou verificar.
      Voz: Há duas: Abacato e Misty.
      """)
    // Sent once; the delegating turn arriving afterwards is not context either.
    context.heard(turn("t2", .user, "E a outra?"))
    context.heard(turn("t3", .user, "Obrigado."))
    #expect(context.lastUser == "Obrigado.")
    #expect(context.request("Confira o Abacato", turn: nil).hasSuffix("\nAlexandre: Obrigado."))
  }

  /// Without turn IDs the delegating turn is recognized by its words, as `VoiceContinuity` does.
  @Test func theDelegatingTurnIsLeftOutByIDOrWords() {
    var context = VoiceRequestContext()
    context.heard(turn(nil, .user, "Tá vendo minha tela?"))
    context.heard(turn(nil, .assistant, "Quer que eu olhe?"))
    context.heard(turn(nil, .user, " tá vendo minha tela "))
    #expect(context.request("Tá vendo minha tela?", turn: nil) == """
      Tá vendo minha tela?

      Conversa por voz desde o pedido anterior (transcrição, pode ter erros):
      Voz: Quer que eu olhe?
      """)
    // Other words with the trigger's ID are still that turn (it went on after the delegation).
    _ = context.request("Abre o Abacato", turn: "t9")
    context.heard(turn("t9", .user, "Abre o Abacato e roda os testes"))
    #expect(context.request("Pronto?", turn: "t10") == "Pronto?")
  }

  @Test func theConversationKeepsTheNewestTurnsWithinTheBudget() {
    var context = VoiceRequestContext()
    for index in 1...9 { context.heard(turn("u\(index)", index.isMultiple(of: 2) ? .assistant : .user, "Fala \(index)")) }
    let lines = context.request("Pedido", turn: nil).components(separatedBy: "\n").dropFirst(3)
    #expect(Array(lines) == ["Voz: Fala 4", "Alexandre: Fala 5", "Voz: Fala 6", "Alexandre: Fala 7", "Voz: Fala 8",
      "Alexandre: Fala 9"], "the newest six")
    let long = String(repeating: "a", count: 700)
    context.heard(turn("o", .assistant, "início " + long))
    context.heard(turn("p", .user, long))
    context.heard(turn("q", .assistant, "curta"))
    let request = context.request("Pedido", turn: nil)
    #expect(request.hasSuffix("\nAlexandre: " + long + "\nVoz: curta"), "the older turn no longer fits")
    #expect(!request.contains("início"))
    context.heard(turn("r", .assistant, "início " + String(repeating: "b", count: 2_000)))
    let clipped = context.request("Pedido", turn: nil).components(separatedBy: "\n").last ?? ""
    #expect(clipped.hasPrefix("Voz: …b") && clipped.count == VoiceRequestContext.characters, "the end of the newest one")
  }

  @Test(arguments: ["Enfileira isso: roda os testes do Mac", "pode enfileirar depois", "Enfileire o pedido",
    "Coloca na fila", "coloca isso na fila", "põe essa tarefa na fila", "POE NA FILA", "sem interromper, vê o PR",
    "Faz isso sem  interromper o que ele está fazendo"])
  func wordsThatQueue(_ text: String) {
    #expect(VoiceQueueIntent.queues(text))
  }

  @Test(arguments: ["Roda os testes", "quantas sessões tem na fila?", "a fila do banco tá enorme", "interrompe a sessão",
    "não interrompe", "coloca o arquivo na pasta", "o pedido foi enfileirado?", "fila"])
  func wordsThatDoNotQueue(_ text: String) {
    #expect(!VoiceQueueIntent.queues(text))
  }
}
