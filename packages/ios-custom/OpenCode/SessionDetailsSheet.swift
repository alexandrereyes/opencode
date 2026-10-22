import OpenCodeKit
import SwiftUI

struct SessionDetailsSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: ConversationStore
  let project: Project?
  let context: () -> Void
  @State private var services: SessionServices?
  var body: some View {
    NavigationStack {
      List {
        Section("Sessão") {
          LabeledContent("Projeto", value: project?.displayName ?? "Indisponível")
          VStack(alignment: .leading, spacing: 5) {
            Text("Diretório de trabalho").foregroundStyle(theme.color(.textSecondary))
            Text(store.located?.worktree ?? store.session?.location.directory ?? "Indisponível").font(.footnote).textSelection(.enabled)
          }
          LabeledContent("Branch", value: services?.branch ?? (services == nil ? "Carregando…" : "Indisponível"))
          if let changes = services?.changes {
            HStack {
              Text("Alterações atuais")
              Spacer()
              Text("+\(changes.reduce(0) { $0 + $1.additions })").foregroundStyle(theme.color(.diffAdd))
              Text("−\(changes.reduce(0) { $0 + $1.deletions })").foregroundStyle(theme.color(.diffDelete))
            }
          } else {
            LabeledContent("Alterações atuais", value: services == nil ? "Carregando…" : "Indisponível")
          }
          Button("Uso de contexto", systemImage: "chart.pie") { dismiss(); context() }
        }
        serviceSection("MCP", items: services?.mcp)
        serviceSection("Plugins", items: services?.plugins)
        serviceSection("Skills", items: services?.skills)
        serviceSection("LSP · configuração", items: services?.lsp)
        Section {
          Text("LSP: status de conexão indisponível. O servidor expõe apenas a configuração.")
            .font(.caption).foregroundStyle(theme.color(.textSecondary))
          Button("Atualizar") { Task { services = await store.services() } }
        }
      }
      .scrollContentBackground(.hidden).background(theme.color(.background))
      .foregroundStyle(theme.color(.textStrong))
      .navigationTitle("Detalhes da sessão").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
    }
    .tint(theme.color(.primary)).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    .task { services = await store.services() }
  }
  private func serviceSection(_ title: String, items: [SessionService]?) -> some View {
    Section(title) {
      if let items {
        if items.isEmpty { Text("Nenhum configurado").foregroundStyle(theme.color(.textSecondary)) }
        ForEach(items) { item in
          LabeledContent {
            Text(item.label).foregroundStyle(theme.color(role(item.state)))
          } label: { Text(item.id).lineLimit(2) }
        }
      } else {
        Text(services == nil ? "Carregando…" : "Indisponível").foregroundStyle(theme.color(.textSecondary))
      }
    }.listRowBackground(theme.color(.toolSurface))
  }
  private func role(_ state: SessionService.State) -> ThemeRole {
    switch state {
    case .active: .success
    case .failed: .error
    case .needsAuth, .pending: .warning
    case .configured, .disabled, .unavailable: .textSecondary
    }
  }
}

struct ConversationNoticeView: View {
  @Environment(\.appTheme) private var theme
  let notice: ConversationNotice
  let retry: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(notice == .incompatible ? "Servidor incompatível" : "Diretório indisponível", systemImage: "exclamationmark.triangle")
        .font(.subheadline.weight(.semibold))
      if case .missingDirectory(let directory) = notice {
        Text("O diretório desta sessão não existe mais. O histórico continua disponível, mas não é possível enviar mensagens.")
        Text(directory).font(.caption).textSelection(.enabled)
      } else {
        Text("Este servidor não oferece a API do OpenCode V2. Atualize o servidor para continuar.")
      }
      Button("Tentar novamente", action: retry).fontWeight(.medium)
    }
    .font(.footnote).foregroundStyle(theme.color(.textStrong)).padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.color(.warning).opacity(0.12))
    .accessibilityIdentifier("conversation-notice")
  }
}
