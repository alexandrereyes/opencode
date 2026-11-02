import Testing
@testable import OpenCodeKit

/// The Watch's `spoken` test in `plugin-app-custom` (`test/watch.test.ts`) uses the same cases: one rule on both platforms.
struct VoiceResultTests {
  @Test func displayMarkdownIsNotSpoken() {
    let text = [
      "## Resumo",
      "",
      "- **Sessão A**: rodando, veja [o PR](https://github.com/x/y/pull/1).",
      "- [x] `bun test` passou",
      "1. __Primeiro__ passo",
      "",
      "> Nota: cuidado",
      "",
      "| Sessão | Estado |",
      "|:---|---:|",
      "| A | rodando |",
      "",
      "```ts",
      "const x = 1",
      "```",
      "~~~",
      "echo oi",
      "~~~",
      "",
      "---",
      "Fim. ![diagrama](d.png)",
    ].joined(separator: "\r\n")
    #expect(VoiceResult.spoken(text) == [
      "Resumo",
      "",
      "Sessão A: rodando, veja o PR.",
      "bun test passou",
      "Primeiro passo",
      "",
      "Nota: cuidado",
      "",
      "Sessão, Estado",
      "A, rodando",
      "",
      "(há código na resposta; veja na conversa)",
      "",
      "Fim. diagrama",
    ].joined(separator: "\n"))
    // An unclosed block runs to the end; a fence with an info string does not close it.
    #expect(VoiceResult.spoken("Rode:\n```sh\nbun test\n```js\nainda código") == "Rode:\n(há código na resposta; veja na conversa)")
    #expect(VoiceResult.spoken("Duas sessões estão rodando.") == "Duas sessões estão rodando.")
  }

  @Test func longResultsKeepTheStartUpToASentenceEnd() {
    let sentence = "A sessão do Abacato terminou os testes e abriu o PR. "
    let long = String(repeating: sentence, count: 40)
    let cut = VoiceResult.spoken(long)
    let rest = "\n\nO restante da resposta está na conversa."
    #expect(cut.hasSuffix(rest))
    let body = String(cut.dropLast(rest.count))
    #expect(body.count <= VoiceResult.limit && body.count > VoiceResult.limit - sentence.count)
    #expect(long.hasPrefix(body) && body.hasSuffix("PR."))
    // Without a sentence end, at the last space; without spaces, a hard cut.
    #expect(VoiceResult.spoken(String(repeating: "palavra ", count: 300)).components(separatedBy: "\n\n").first
      == String(repeating: "palavra ", count: 187).trimmingCharacters(in: .whitespaces))
    #expect(VoiceResult.spoken(String(repeating: "a", count: 2_000)).components(separatedBy: "\n\n").first
      == String(repeating: "a", count: VoiceResult.limit))
  }
}
