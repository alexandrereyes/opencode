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
  @State private var thumbnails = ResourceThumbnails()
  /// Not remembered: the screen always opens on Agentes.
  @State private var tab = Tab.agents
  enum Tab: Hashable { case agents, scripts }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The order on screen. It follows `store.work` (running first, then by latest activity) but only changes
  /// while the list is not being scrolled, with a short animation, so a finishing agent never moves under a finger.
  @State private var shown: [String] = []
  @State private var scrolling = false
  private var ordered: [SessionWork] {
    let index = Dictionary(shown.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    return store.work.enumerated()
      .sorted { (index[$0.element.id] ?? Int.max, $0.offset) < (index[$1.element.id] ?? Int.max, $1.offset) }
      .map(\.element)
  }
  private var agents: [SessionWork] { ordered.filter { $0.kind == .agent } }
  private var scripts: [SessionWork] { ordered.filter { $0.kind == .script } }
  private func reorder(_ ids: [String]) {
    guard !scrolling, ids != shown else { return }
    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { shown = ids }
  }
  /// Resources used by this session itself (or by descendants without a row here).
  private var ownResources: [SessionResource] {
    store.resources.filter { resource in !agents.contains { $0.sessionID != nil && $0.sessionID == resource.owner?.sessionID } }
  }
  static func runningLabel(agents: Int, scripts: Int) -> String {
    let parts = [
      agents == 0 ? nil : agents == 1 ? "1 agente" : "\(agents) agentes",
      scripts == 0 ? nil : scripts == 1 ? "1 script" : "\(scripts) scripts",
    ].compactMap { $0 }
    return parts.isEmpty ? "Agentes e tarefas" : parts.joined(separator: " e ") + " em execução"
  }
  var body: some View {
    List {
      switch tab {
      case .agents: agentsTab
      case .scripts: scriptsTab
      }
    }
    .onScrollPhaseChange { _, phase in
      scrolling = phase != .idle
      reorder(store.work.map(\.id))
    }
    .onChange(of: store.work.map(\.id), initial: true) { _, ids in
      if shown.isEmpty { shown = ids } else { reorder(ids) }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      Picker("Lista", selection: $tab) {
        Text("Agentes (\(agents.count))").tag(Tab.agents)
        Text("Scripts (\(scripts.count))").tag(Tab.scripts)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, AppLayout.margin).padding(.vertical, 8)
      .background(theme.color(.background))
      .accessibilityIdentifier("agents-tabs")
    }
    .scrollContentBackground(.hidden).background(theme.color(.background))
    .foregroundStyle(theme.color(.textStrong))
    .navigationTitle("Agentes e tarefas").navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .tint(theme.color(.primary))
    .toastOverlay(store.toast)
    .sessionAlertOverlay()
    // The conversation below stops listening while covered; keep this list live.
    .task(id: scenePhase) { if scenePhase == .active { await store.run() } }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      await thumbnails.run({ store.resources }, client: sessions.client)
    }
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
  @ViewBuilder private var agentsTab: some View {
    if !ownResources.isEmpty {
      Section {
        ForEach(ownResources) { resource in
          resourceRow(resource, via: resource.owner?.sessionID == store.id ? nil : resource.owner?.agent)
        }
      } header: {
        Text("Esta sessão" + (store.session?.agent.map { " · \($0)" } ?? ""))
      }
    }
    Section {
      ForEach(agents) { work in
        workRow(work)
        // A subagent without resources shows nothing below its row.
        if let child = work.sessionID {
          ForEach(store.resources.filter { $0.owner?.sessionID == child }) { resource in
            resourceRow(resource, nested: true)
          }
        }
      }
      if agents.isEmpty {
        Text("Nenhum subagente nesta sessão.").foregroundStyle(theme.color(.textSecondary))
          .listRowBackground(theme.color(.surface))
      }
    } header: {
      if !store.resources.isEmpty { Text("Subagentes") }
    }
  }
  @ViewBuilder private var scriptsTab: some View {
    Section {
      ForEach(scripts) { work in workRow(work) }
      if scripts.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Nenhum script em segundo plano.").foregroundStyle(theme.color(.text))
          Text("Comandos que o agente deixa rodando em segundo plano aparecem aqui.")
            .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        }.padding(.vertical, 4).listRowBackground(theme.color(.surface))
          .accessibilityElement(children: .combine).accessibilityIdentifier("scripts-empty")
      }
    }
  }
  private func workRow(_ work: SessionWork) -> some View {
    row(work)
      .swipeActions { if work.running { Button("Parar", role: .destructive) { stopping = work } } }
      .contextMenu {
        if work.running { Button("Parar", systemImage: "stop.fill", role: .destructive) { stopping = work } }
      }
      .listRowBackground(theme.color(.surface))
  }
  private func row(_ work: SessionWork) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Button {
        open(work)
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 12) {
            let agent = store.agents.first { $0.id == work.agent }
            if work.kind == .script {
              Image(systemName: "terminal").foregroundStyle(theme.color(.textSecondary))
            } else {
              AgentPixels(color: work.agent.map { theme.agentColor(agent, id: $0) } ?? theme.color(.textSecondary),
                running: work.running || work.state == .starting)
            }
            VStack(alignment: .leading, spacing: 4) {
              if work.kind == .script {
                Text(work.title).appFont(.caption, design: .monospaced).foregroundStyle(theme.color(.text))
                  .lineLimit(3)
              } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text(agent?.name ?? work.agent ?? "Subagente")
                    .appFont(.secondary, weight: .medium).foregroundStyle(
                      work.agent.map { theme.agentColor(agent, id: $0) } ?? theme.color(.text))
                    .lineLimit(1).layoutPriority(1)
                  if let model = work.model {
                    Text(store.modelLabel(model)).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
                      .lineLimit(1).accessibilityIdentifier("agent-model-" + work.id)
                  }
                }
                Text(work.title).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
                  .lineLimit(2)
              }
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
  private func resourceRow(_ resource: SessionResource, nested: Bool = false, via: String? = nil) -> some View {
    ResourceRow(resource: resource, image: thumbnails.images[resource.id], via: via) {
      sessions.openResource = resource
    }
    .padding(.leading, nested ? 30 : 0)
    .background(alignment: .leading) {
      if nested {
        // Tree connector from the subagent above.
        GeometryReader { geometry in
          Path { path in
            path.move(to: CGPoint(x: 12, y: -12))
            path.addLine(to: CGPoint(x: 12, y: geometry.size.height / 2))
            path.addLine(to: CGPoint(x: 26, y: geometry.size.height / 2))
          }
          .stroke(theme.color(.border), lineWidth: 1.2)
        }
        .frame(width: 30).accessibilityHidden(true)
      }
    }
    .contextMenu {
      Button("Abrir", systemImage: "rectangle.on.rectangle") { sessions.openResource = resource }
      if !resource.state.running {
        Button("Remover da lista", systemImage: "xmark.circle", role: .destructive) {
          Task {
            try? await sessions.client.dismissResource(resource.id)
            store.scheduleResources()
          }
        }
      }
    }
    .listRowBackground(theme.color(.surface))
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
