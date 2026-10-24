import OpenCodeKit
import SwiftUI

/// The owner's subagents and background shells, running and finished alike, as a pushed screen.
struct ConversationAgentsView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  let store: ConversationStore
  let sessions: SessionStore
  @State private var stopping: SessionWork?
  var body: some View {
    List {
      ForEach(store.work) { work in
        row(work)
          .swipeActions { if work.running { Button("Parar", role: .destructive) { stopping = work } } }
          .contextMenu {
            if work.running { Button("Parar", systemImage: "stop.fill", role: .destructive) { stopping = work } }
          }
          .listRowBackground(theme.color(.surface))
      }
      if store.work.isEmpty {
        Text("Nenhum agente nesta sessão.").foregroundStyle(theme.color(.textSecondary))
          .listRowBackground(theme.color(.surface))
      }
    }
    .scrollContentBackground(.hidden).background(theme.color(.background))
    .foregroundStyle(theme.color(.textStrong))
    .navigationTitle("Agentes e tarefas").navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbar(.hidden, for: .tabBar)
    .tint(theme.color(.primary))
    .toastOverlay(store.toast)
    .sessionAlertOverlay()
    // The conversation below stops listening while covered; keep this list live.
    .task(id: scenePhase) { if scenePhase == .active { await store.run() } }
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
  }
  private func row(_ work: SessionWork) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Button {
        open(work)
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 12) {
            let agent = store.agents.first { $0.id == work.agent }
            if let id = work.agent {
              AgentPixels(color: theme.agentColor(agent, id: id), running: work.running)
            } else {
              Image(systemName: "terminal").foregroundStyle(theme.color(.textSecondary))
            }
            VStack(alignment: .leading, spacing: 4) {
              Text(agent?.name ?? work.agent ?? "Shell em background")
                .appFont(.secondary, weight: .medium).foregroundStyle(
                  work.agent.map { theme.agentColor(agent, id: $0) } ?? theme.color(.text))
              Text(work.title).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
                .lineLimit(2)
              state(work)
            }
            Spacer(minLength: 3)
            if work.sessionID != nil || work.toolID != nil {
              Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.icon))
            }
          }
          if let usage = store.childUsage(work.sessionID) {
            ContextUsageLine(usage: usage, compact: true).padding(.leading, 30)
              .accessibilityIdentifier("child-usage-" + work.id)
          }
        }.padding(.vertical, 5).contentShape(.rect)
      }
      .buttonStyle(.plain).disabled(work.sessionID == nil && work.toolID == nil)
      .accessibilityValue(work.state.label)
      .accessibilityIdentifier("agent-work-" + work.id)
      // Finished rows keep the stop column so every row lines up.
      if work.running {
        Button {
          stopping = work
        } label: {
          Image(systemName: "stop.circle").appSymbol(.action).foregroundStyle(theme.color(.error))
            .frame(width: 32, height: 40)
        }.buttonStyle(.borderless).accessibilityLabel("Parar \(work.title)")
      } else {
        Color.clear.frame(width: 32, height: 40).accessibilityHidden(true)
      }
    }
  }
  private func state(_ work: SessionWork) -> some View {
    HStack(spacing: 5) {
      switch work.state {
      case .starting: Image(systemName: "hourglass").foregroundStyle(theme.color(.textSecondary))
      case .running: Circle().fill(theme.color(.success)).frame(width: 7, height: 7)
      case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.color(.success))
      case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(theme.color(.error))
      case .interrupted: Image(systemName: "stop.circle.fill").foregroundStyle(theme.color(.warning))
      case .ended: Image(systemName: "minus.circle.fill").foregroundStyle(theme.color(.textWeak))
      }
      Text(work.state.label)
      if work.running {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text("· " + ConversationProjection.duration(context.date.timeIntervalSince1970 * 1000 - work.started))
            .monospacedDigit()
        }
      } else if let duration = work.duration {
        Text("· " + ConversationProjection.duration(duration)).monospacedDigit()
      }
    }.appFont(.micro).foregroundStyle(theme.color(.textSecondary))
  }
  private func open(_ work: SessionWork) {
    if let child = work.sessionID {
      sessions.conversationPath.append(.init(id: child, parent: store.id))
      return
    }
    guard let tool = work.toolID else { return }
    if let parent = store.session?.parentID {
      sessions.conversationPath.append(.init(id: parent, parent: store.id, tool: tool))
      return
    }
    store.toolRequest = tool
    dismiss()
  }
}

struct ConversationContextSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: ConversationStore
  var showLocation = true
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
          if showLocation {
            row("Branch", store.branch)
            VStack(alignment: .leading, spacing: 7) {
              Text("Diretório").font(.subheadline)
              Text(store.session?.location.directory ?? "—").font(.caption).textSelection(.enabled)
                .foregroundStyle(theme.color(.textSecondary))
            }
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
