import Foundation
import Testing
@testable import OpenCodeKit

struct DictationReviewTests {
  @Test func everyRecordingStartsWithTheReviewOnWhateverTheLastOneChose() {
    var revision = DictationRevision()
    #expect(revision.enabled)
    let toggled = revision.toggle()
    #expect(toggled == nil && !revision.enabled)
    let asked = revision.transcribed("texto cru", reviewer: true)
    #expect(!asked)
    revision.begin()
    #expect(revision.enabled && revision.reviewing == nil)
    // On, but no reviewer (a composer without a server): the raw text goes in.
    let unasked = revision.transcribed("texto cru", reviewer: false)
    #expect(!unasked && revision.reviewing == nil)
  }

  @Test func theRevisionArrivesAsTwoUndoStepsAndAnUnchangedOneAsOne() {
    var revision = DictationRevision()
    let asked = revision.transcribed("texto cru", reviewer: true)
    #expect(asked && revision.reviewing == "texto cru")
    let edits = revision.reviewed("texto cru", revised: "Texto cru.")
    #expect(edits == ["texto cru", "Texto cru."] && revision.reviewing == nil)
    #expect(DictationReview.edits(raw: "igual", revised: "igual") == ["igual"])
    #expect(DictationReview.edits(raw: "cru", revised: "") == ["cru"])
  }

  @Test func aFailedOrTimedOutReviewInsertsTheRawText() {
    var revision = DictationRevision()
    _ = revision.transcribed("texto cru", reviewer: true)
    let edits = revision.reviewed("texto cru", revised: nil)
    #expect(edits == ["texto cru"])
  }

  @Test func usarOriginalInsertsTheRawTextAndIgnoresTheLateReply() {
    var revision = DictationRevision()
    _ = revision.transcribed("texto cru", reviewer: true)
    let original = revision.useOriginal()
    let late = revision.reviewed("texto cru", revised: "Texto cru.")
    #expect(original == "texto cru" && late == nil)
    // The switch during the review is Usar original too.
    revision.begin()
    _ = revision.transcribed("outro", reviewer: true)
    let switched = revision.toggle()
    let ignored = revision.reviewed("outro", revised: "Outro.")
    #expect(switched == "outro" && revision.enabled && ignored == nil)
  }

  @Test func cancellingTheReviewInsertsNothing() {
    var revision = DictationRevision()
    _ = revision.transcribed("texto cru", reviewer: true)
    revision.cancel()
    let late = revision.reviewed("texto cru", revised: "Texto cru.")
    let original = revision.useOriginal()
    #expect(revision.reviewing == nil && late == nil && original == nil)
  }

  @Test func theContextIsWhatTheComposerShowsAsItIs() {
    func message(_ id: String, _ type: String, text: String? = nil, parts: [ConversationPart]? = nil) -> ConversationMessage {
      var value = ConversationMessage(id: id, type: type, time: MessageTime(created: 0))
      value.text = text
      value.content = parts
      return value
    }
    let messages = [message("1", "user", text: "primeira")]
      + (2...8).map { message("\($0)", "user", text: "pergunta \($0)") }
      + [message("9", "shell", text: "ls"),
         message("10", "assistant", parts: [ConversationPart(type: "reasoning", text: "pensando"),
           ConversationPart(type: "text", text: "Resposta"), ConversationPart(type: "text", text: "final")])]
    let turns = DictationReview.turns(messages)
    #expect(turns.count == 6)
    #expect(turns.first == .init(.user, "pergunta 4"))
    #expect(turns.last == .init(.assistant, "Resposta\n\nfinal"))
    #expect(DictationReview.turns([SideQuestionEntry(question: "Por quê?", answer: "Porque sim."),
      SideQuestionEntry(question: "E agora?")]) == [.init(.user, "Por quê?"), .init(.assistant, "Porque sim."), .init(.user, "E agora?")])
    #expect(DictationReview.context(draft: "  rascunho ", turns: [.init(.user, "oi"), .init(.assistant, "olá")])
      == "User: oi\n\nAssistant: olá\n\nDraft:\nrascunho")
    #expect(DictationReview.context(draft: "", quote: "trecho citado") == "Quoted passage:\ntrecho citado")
    #expect(DictationReview.context(draft: " \n") == nil)
    // Only the end of a long message.
    let long = String(repeating: "a", count: 3_000) + "fim"
    let context = DictationReview.context(draft: "", turns: [.init(.assistant, long)])
    #expect(context?.hasSuffix("fim") == true)
    #expect((context?.count ?? 0) < 1_600)
  }

  @Test func theClientReturnsTheRevisionOnlyWhenTheServerRevised() async {
    func client(_ status: Int, _ body: String) -> OpenCodeClient {
      OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!), transport: { request in
        #expect(request.url?.path == "/api/rpc/custom.dictation/review")
        let sent = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(sent.object?["input"]?.object?["text"]?.string == "texto cru")
        #expect(sent.object?["input"]?.object?["context"]?.string == "Draft:\nrascunho")
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
      })
    }
    #expect(await client(200, #"{"output":{"text":"Texto cru.","revised":true}}"#)
      .reviewDictation("texto cru", context: "Draft:\nrascunho") == "Texto cru.")
    #expect(await client(200, #"{"output":{"text":"texto cru","revised":false}}"#)
      .reviewDictation("texto cru", context: "Draft:\nrascunho") == nil)
    // An older server without the RPC.
    #expect(await client(404, #"{"message":"not found"}"#).reviewDictation("texto cru", context: "Draft:\nrascunho") == nil)
  }
}
