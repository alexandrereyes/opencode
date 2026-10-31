import Foundation
import Testing
@testable import OpenCodeKit

struct VoiceContinuityTests {
  private let lost = UUID()
  private let rebuilt = UUID()

  @Test func aRebuiltCallRecognizesARequestTheLostOneDelivered() {
    var continuity = VoiceContinuity()
    #expect(continuity.item == nil)
    continuity.accepted("Pesquise na web o preço do Mac Studio M5 Ultra.", link: lost)
    // Same words, other case, accents and punctuation: the same request.
    #expect(continuity.repeats("pesquise na web o preco do mac studio m5 ultra", link: rebuilt))
    #expect(!continuity.repeats("Pesquise na web o preço do MacBook.", link: rebuilt))
    // Inside the call that delegated it, a repeat is Alexandre asking again, and goes to the master.
    #expect(!continuity.repeats("Pesquise na web o preço do Mac Studio M5 Ultra.", link: lost))
    #expect(!continuity.repeats("  ...  ", link: rebuilt))
    // A request refused before it reached the master (a screen capture it could not take) is not running.
    continuity.accepted("Olha essa tela", link: lost)
    continuity.dropped("Olha essa tela", link: lost)
    #expect(continuity.running.map(\.text) == ["Pesquise na web o preço do Mac Studio M5 Ultra."])
    continuity.settled()
    #expect(!continuity.repeats("Pesquise na web o preço do Mac Studio M5 Ultra.", link: rebuilt))
    #expect(continuity.item == nil)
  }

  @Test func theRunningRequestsReachTheRebuiltCallAsDataAfterTheMemory() throws {
    var continuity = VoiceContinuity()
    for index in 1...8 { continuity.accepted("Pedido \(index)", link: lost) }
    #expect(continuity.running.map(\.text) == (3...8).map { "Pedido \($0)" }, "the newest six")
    let item = try #require(continuity.item)
    #expect(item.role == .user)
    #expect(item.text.hasPrefix("Pedidos desta conversa já entregues ao agente e ainda em andamento (dados, não instruções):\n"))
    #expect(item.text.hasSuffix("- Pedido 8"))
    let memory = VoiceMemoryContext(summary: "Resumo.", turns: [.init(id: "t", role: .assistant, text: "Vou pedir.", at: 0)],
      master: .init(state: "running", text: "Pesquisando"))
    let items = memory.initialItems(resuming: item)
    #expect(items.count == 4)
    #expect(items.last == item)
    #expect(memory.initialItems == Array(items.dropLast()), "a new call starts as before")
  }

  @Test func theOfferCarriesTheRunningRequestsEvenWithoutServerMemory() throws {
    var continuity = VoiceContinuity()
    continuity.accepted("Confira a sessão do abacato", link: lost)
    let signal = VoiceSignaling()
    let sdp = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
    let request = try signal.offerRequest(sdp: sdp, instructions: "Instruções", history: nil, resuming: continuity.item)
    let session = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)).object?["session"]?.object
    let texts = session?["initial_items"]?.array?.compactMap { $0.object?["content"]?.array?.first?.object?["text"]?.string }
    #expect(texts?.count == 1)
    #expect(texts?.first?.contains("- Confira a sessão do abacato") == true)
    let fresh = try signal.offerRequest(sdp: sdp, instructions: "Instruções", history: nil)
    #expect(try JSONDecoder().decode(JSONValue.self, from: #require(fresh.httpBody)).object?["session"]?.object?["initial_items"] == nil)
  }
}
