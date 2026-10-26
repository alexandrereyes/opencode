#if DEBUG
import Foundation

/// Server-free side-question answers for the offline conversation fixture (`-OpenCodeSideQuestionFixture`).
@MainActor enum SideQuestionFixture {
  static var enabled: Bool {
    ["conversation", "catalog"].contains(ScrollFixtures.mode ?? "")
      && ProcessInfo.processInfo.arguments.contains("-OpenCodeSideQuestionFixture")
  }
  static func answer() async throws -> String {
    try await Task.sleep(for: .milliseconds(300))
    if ScrollFixtures.mode == "catalog" {
      return "Comece pelos **filtros de projetos**.\n\n1. Compare os caminhos mais usados.\n2. Faça uma mudança pequena.\n3. Valide a navegação nos temas claro e escuro.\n\nA conversa principal continua no mesmo ponto."
    }
    return """
      Para você avaliar um caso, precisa existir uma resposta para avaliar. Explico em três passos:

      1. **O caso, quando nasce, tem só a pergunta.** O modelo que gera os casos escreve o perfil, o contexto, o \
      mundo fictício e a mensagem da usuária. Por exemplo: "Resume o que falaram no grupo da família hoje". Ainda não \
      há resposta da IA.
      2. **O Core roda o Assistente nesse caso para produzir a resposta.** O Assistente sempre roda com algum prompt: \
      a "versão ativa", que é a que está valendo naquele momento.
      3. **Na primeira vez, esse prompt está vazio,** como você disse: o prompt do Assistente é só as skills e as \
      ferramentas, sem instruções extras.

      Depois disso, cada avaliação compara a resposta com o que se esperava e sugere ajustes ao prompt. Uma nova \
      versão só passa a valer quando você a ativa, e os casos seguintes já usam essa versão.

      Em resumo: primeiro a pergunta, depois a resposta gerada com a versão ativa, e só então a avaliação.

      Última linha da resposta paralela.
      """
  }
}
#endif
