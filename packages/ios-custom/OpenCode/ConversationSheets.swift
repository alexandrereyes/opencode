import OpenCodeKit
import SwiftUI

struct ConversationAgentsSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: ConversationStore
  let open: (RunningWork) -> Void
  @State private var stopping: RunningWork?
  @State private var rowHeights: [String: CGFloat] = [:]
  var body: some View {
    NavigationStack {
      List {
        ForEach(store.runningWork) { work in
          HStack(spacing: 8) {
            Button {
              dismiss()
              open(work)
            } label: {
              HStack(spacing: 12) {
                let agent = store.agents.first { $0.id == work.agent }
                if let id = work.agent {
                  AgentPixels(color: theme.agentColor(agent, id: id))
                } else {
                  Image(systemName: "terminal").foregroundStyle(theme.color(.textSecondary))
                }
                ViewThatFits(in: .horizontal) {
                  HStack(spacing: 8) {
                    Text(agent?.name ?? "Shell em background")
                      .font(.subheadline.weight(.medium))
                      .foregroundStyle(
                        work.agent.map { theme.agentColor(agent, id: $0) } ?? theme.color(.text)
                      ).fixedSize()
                    Text(work.title).font(.caption).foregroundStyle(theme.color(.textSecondary))
                      .fixedSize()
                  }
                  VStack(alignment: .leading, spacing: 5) {
                    Text(
                      work.agent.flatMap { id in store.agents.first { $0.id == id }?.name }
                        ?? "Shell em background"
                    )
                    .font(.subheadline.weight(.medium)).foregroundStyle(
                      work.agent.map { theme.agentColor(agent, id: $0) } ?? theme.color(.text))
                    Text(work.title).font(.caption).foregroundStyle(theme.color(.textSecondary))
                      .lineLimit(2)
                  }
                }
                Spacer(minLength: 3)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                  Text(
                    ConversationProjection.duration(
                      context.date.timeIntervalSince1970 * 1000 - work.started)
                  )
                  .font(.caption2).monospacedDigit().foregroundStyle(theme.color(.textSecondary))
                  .fixedSize()
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(
                  theme.color(.icon))
              }.padding(.vertical, 5)
            }.buttonStyle(.plain).disabled(work.sessionID == nil && work.shellID == nil)
            Button {
              stopping = work
            } label: {
              Image(systemName: "stop.circle").font(.title3).foregroundStyle(theme.color(.error))
                .frame(width: 32, height: 40)
            }.buttonStyle(.borderless).accessibilityLabel("Parar \(work.title)")
          }
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: { height in
            rowHeights[work.id] = height
          }
          .swipeActions { Button("Parar", role: .destructive) { stopping = work } }
          .contextMenu {
            Button("Parar", systemImage: "stop.fill", role: .destructive) { stopping = work }
          }
          .listRowBackground(theme.color(.surface))
        }
        if store.runningWork.isEmpty {
          Text("Nenhuma tarefa em execução.").foregroundStyle(theme.color(.textSecondary))
        }
      }
      .scrollContentBackground(.hidden).background(theme.color(.background))
      .toastOverlay(store.toast)
      .navigationTitle("Agentes e tarefas").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluir") { dismiss() } } }
      .confirmationDialog(
        "Parar esta tarefa?",
        isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
        titleVisibility: .visible
      ) {
        if let stopping {
          Button("Parar", role: .destructive) { Task { await store.stop(stopping) } }
          Button("Cancelar", role: .cancel) {}
        }
      } message: {
        Text(stopping?.title ?? "")
      }
    }.presentationDetents([
      .height(
        min(
          580, max(180, store.runningWork.reduce(0) { $0 + (rowHeights[$1.id] ?? 48) + 16 } + 112)))
    ]).presentationDragIndicator(.visible).tint(
      theme.color(.primary))
  }
}

struct ConversationContextSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: ConversationStore
  private var details: ContextDetails { store.details }
  @State private var detent = PresentationDetent.medium
  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(spacing: 12) {
            ZStack {
              Circle().stroke(theme.color(.contextTrack), lineWidth: 9)
              Circle().trim(from: 0, to: min(1, max(0, details.fraction ?? 0)))
                .stroke(
                  theme.color((details.fraction ?? 0) > 0.8 ? .contextWarning : .contextFill),
                  style: StrokeStyle(lineWidth: 9, lineCap: .round)
                ).rotationEffect(.degrees(-90))
              Text(details.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").font(
                .title.weight(.medium))
            }.frame(width: 112, height: 112)
            Text("\(number(details.total)) / \(number(details.model?.limit.context)) tokens").font(
              .subheadline)
            Text("Último passo medido; não inclui mensagens na fila.").font(.caption)
              .foregroundStyle(theme.color(.textSecondary))
          }.frame(maxWidth: .infinity).padding(.vertical, 12)
            .listRowBackground(theme.color(.surface))
        }
        Section("Tokens") {
          row("Entrada", number(details.tokens?.input))
          row("Saída", number(details.tokens?.output))
          row("Raciocínio", number(details.tokens?.reasoning))
          row("Cache lido", number(details.tokens?.cache.read))
          row("Cache escrito", number(details.tokens?.cache.write))
          row("Acerto de cache", details.cacheHit.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
        }
        Section("Custo") {
          row("Esta sessão", money(details.sessionCost))
          row("Subagentes", money(details.familyCost))
          row("Total", money(details.totalCost))
        }
        Section("Sessão") {
          row("Modelo", details.model?.name ?? details.reference?.id ?? "—")
          row("Provedor", details.reference?.providerID ?? "—")
          row("Branch", store.branch)
          VStack(alignment: .leading, spacing: 7) {
            Text("Diretório").font(.subheadline)
            Text(store.session?.location.directory ?? "—").font(.caption).textSelection(.enabled)
              .foregroundStyle(theme.color(.textSecondary))
          }
        }
      }
      .scrollContentBackground(.hidden).background(theme.color(.background)).foregroundStyle(
        theme.color(.text)
      )
      .navigationTitle("Contexto da conversa").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluir") { dismiss() } } }
    }.presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
      .tint(theme.color(.primary))
  }
  private func row(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).foregroundStyle(theme.color(.textSecondary)).multilineTextAlignment(.trailing)
    }
    .font(.subheadline).listRowBackground(theme.color(.surface))
  }
  private func number(_ value: Double?) -> String {
    value.map {
      $0.formatted(.number.locale(Locale(identifier: "pt_BR")).precision(.fractionLength(0)))
    } ?? "—"
  }
  private func money(_ value: Double?) -> String {
    value.map {
      $0.formatted(
        .currency(code: "USD").locale(Locale(identifier: "pt_BR")).precision(.fractionLength(4)))
    } ?? "—"
  }
}
