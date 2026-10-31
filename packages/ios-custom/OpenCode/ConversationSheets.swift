import OpenCodeKit
import SwiftUI

/// The owner's subagents and background shells, running and finished alike, as a pushed screen. A subagent's own
/// screen lists its own subagents. Each subagent is a line in the Mac's Contexto grammar (approved option 1,
/// 30/10): the title shimmering while it runs, `agente · Modelo · esforço`, `◔ 48% · ⚡ 100% · US$ 8,58 · 4m28s ·
/// ☑ 2/4` (the Progresso opens its list) and `agora: …`, or what it asks Alexandre with Permitir · Negar.
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
  /// The finished subagents past the first ones, behind "+N concluídos".
  @State private var expanded = false
  /// The live subagents' current tool without a Progresso (`agora: rodando bun test`), from their transcript tail.
  @State private var activities: [String: String] = [:]
  @State private var progressSheet: ProgressSheet?
  /// "Abrir subagente" in the Progresso sheet, applied once it has dismissed.
  @State private var openAfterSheet: SessionWork?
  private struct ProgressSheet: Identifiable {
    let work: SessionWork
    let progress: SessionProgress
    var id: String { work.id }
  }
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
  /// Each subagent's open Progresso: the app's live list, else the family snapshot's (`SessionStore.progress`).
  private var progress: [String: SessionProgress] {
    Dictionary(agents.compactMap(\.sessionID).compactMap { id in
      sessions.progress(id, family: store.family).flatMap { $0.open ? (id, $0) : nil }
    }, uniquingKeysWith: { first, _ in first })
  }
  /// Live first, then the newest finished up to five, the rest behind "+N concluídos" (`ContextColumn.subagents`).
  private var subagents: ContextColumn.Subagents {
    ContextColumn.subagents(
      work: agents, rootID: store.id, members: store.children, models: store.displayModels,
      permissions: store.family?.permissions ?? [], forms: store.family?.forms ?? [], resources: store.resources,
      progress: progress.mapValues { ContextColumn.Progress(done: $0.done, total: $0.total) })
  }
  /// Changes when a live subagent takes a step, so its `agora: …` is read again.
  private var activityKey: String {
    agents.filter(\.live).compactMap(\.sessionID).map { id in
      id + ":" + String(store.children.first { $0.id == id }?.time.updated ?? 0)
    }.joined(separator: ",")
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
    .task(id: activityKey) {
      // Coalesces a burst of steps; at most a few previews at a time, like the Sessões rows.
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      await loadActivities()
    }
    .sheet(item: $progressSheet, onDismiss: {
      guard let work = openAfterSheet else { return }
      openAfterSheet = nil
      open(work)
    }) { sheet in
      progressSheetView(sheet)
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
    let subagents = self.subagents
    Section {
      ForEach(subagents.shown + (expanded ? subagents.hidden : [])) { subagent in
        agentRow(subagent)
        // A subagent without resources shows nothing below its row.
        if let child = subagent.work.sessionID {
          ForEach(store.resources.filter { $0.owner?.sessionID == child }) { resource in
            resourceRow(resource, nested: true)
          }
        }
      }
      if !subagents.hidden.isEmpty {
        Button {
          withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
          HStack {
            Text(expanded ? "Ocultar concluídos" : "+\(subagents.hidden.count) concluídos")
            Spacer()
            Image(systemName: expanded ? "chevron.up" : "chevron.right").appSymbol(.disclosure)
              .foregroundStyle(theme.color(.icon))
          }
          .appFont(.secondary).foregroundStyle(theme.color(.text)).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.color(.surface))
        .accessibilityIdentifier("agents-finished-toggle")
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
  /// A background script: its command, state and stop action.
  private func row(_ work: SessionWork) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Button {
        open(work)
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "terminal").foregroundStyle(theme.color(.textSecondary))
          VStack(alignment: .leading, spacing: 4) {
            Text(work.title).appFont(.caption, design: .monospaced).foregroundStyle(theme.color(.text))
              .lineLimit(3)
            state(work)
          }
          Spacer(minLength: 3)
          if work.sessionID != nil || work.toolID != nil {
            Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.icon))
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
  // MARK: Subagent line

  private func agentRow(_ subagent: ContextColumn.Subagent) -> some View {
    let work = subagent.work
    let agent = store.agents.first { $0.id == work.agent }
    return HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Button {
          open(work)
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              agentTitle(subagent)
              Spacer(minLength: 4)
              if work.sessionID != nil || work.toolID != nil {
                Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.icon))
              }
            }
            // `astramax · Astra 6 · max`: who runs it and with which model now.
            HStack(spacing: 4) {
              Text(agent?.name ?? work.agent ?? "Subagente")
                .foregroundStyle(work.agent.map { theme.agentColor(agent, id: $0) } ?? theme.color(.text))
                .layoutPriority(1)
              if let model = work.model {
                Text("·").foregroundStyle(theme.color(.textWeak))
                Text(store.modelLabel(model)).foregroundStyle(theme.color(.textSecondary))
                  .accessibilityIdentifier("agent-model-" + work.id)
              }
            }
            .appFont(.caption).lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(work.sessionID == nil && work.toolID == nil)
        .accessibilityValue(work.state.label)
        .accessibilityIdentifier("agent-work-" + work.id)
        metrics(subagent)
        activityLine(subagent)
      }
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
    .padding(.vertical, 5)
    // A finished line steps back, below a running title's dimmer base between passes.
    .opacity(subagent.status.live ? 1 : 0.55)
    .contentShape(.rect)
    .onTapGesture { open(work) }
    .swipeActions { if work.running { Button("Parar", role: .destructive) { stopping = work } } }
    .contextMenu {
      if work.sessionID != nil { Button("Abrir subagente", systemImage: "bubble.left") { open(work) } }
      if work.running { Button("Parar", systemImage: "stop.fill", role: .destructive) { stopping = work } }
    }
    .listRowBackground(theme.color(.surface))
  }

  /// A running title shimmers like the web's; one waiting for Alexandre carries an amber `?`.
  @ViewBuilder private func agentTitle(_ subagent: ContextColumn.Subagent) -> some View {
    let text = subagent.work.title
    if subagent.status == .permission || subagent.status == .question {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        plainTitle(text)
        Image(systemName: "questionmark.circle").appSymbol(.inline).foregroundStyle(theme.color(.warning))
          .accessibilityLabel(subagent.status.label)
      }
    } else if (subagent.status == .running || subagent.status == .starting) && !reduceMotion {
      ShimmerText(text: text, font: AppTypography.font(.secondary, weight: .medium),
        base: theme.uiColor(.textSecondary), peak: theme.uiColor(.textStrong))
        .accessibilityLabel(text)
        .accessibilityIdentifier("subagent-shimmer-" + subagent.id)
    } else {
      plainTitle(text)
    }
  }

  private func plainTitle(_ text: String) -> some View {
    Text(text).appFont(.secondary, weight: .medium).foregroundStyle(theme.color(.textStrong)).lineLimit(2)
  }

  /// `◔ 48% · 606,9k / 1,1M · ⚡ 100% · US$ 8,58 · 4m28s · ☑ 2/4`: the tokens drop when it does not fit; the
  /// Progresso opens its whole list.
  private func metrics(_ subagent: ContextColumn.Subagent) -> some View {
    TimelineView(.periodic(from: .now, by: subagent.work.running ? 1 : 3_600)) { context in
      let work = subagent.work
      let elapsed = work.running
        ? ConversationProjection.duration(context.date.timeIntervalSince1970 * 1000 - work.started)
        : work.duration.map(ConversationProjection.duration)
      ViewThatFits(in: .horizontal) {
        metricsRow(subagent, elapsed: elapsed, narrow: false)
        metricsRow(subagent, elapsed: elapsed, narrow: true)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agent-metrics-" + subagent.id)
  }

  private func metricsRow(_ subagent: ContextColumn.Subagent, elapsed: String?, narrow: Bool) -> some View {
    HStack(spacing: 5) {
      ContextMetricsLine(
        metrics: ContextColumn.metrics(usage: subagent.usage, cacheHit: subagent.cacheHit, cost: subagent.cost,
          elapsed: elapsed, narrow: narrow),
        usage: subagent.usage)
      if let count = subagent.progress, let child = subagent.work.sessionID, let list = progress[child] {
        Text("·").appFont(.footnote).foregroundStyle(theme.color(.textWeak))
        Button {
          progressSheet = ProgressSheet(work: subagent.work, progress: list)
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "checklist").font(.system(size: 9)).foregroundStyle(theme.color(.textSecondary))
            Text(count.label).foregroundStyle(theme.color(.text))
          }
          .appFont(.footnote).monospacedDigit()
          // A finger-sized target around the small count, without moving the line.
          .padding(.vertical, 12).padding(.horizontal, 8).contentShape(.rect)
          .padding(.vertical, -12).padding(.horizontal, -8)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Progresso \(count.done) de \(count.total)")
        .accessibilityIdentifier("agent-progress-" + subagent.id)
      }
    }
    .lineLimit(1)
  }

  /// `agora: <item do Progresso>` or the current tool; what it asks Alexandre, with Permitir · Negar or
  /// Responder; a finished line says how it ended.
  private func activityLine(_ subagent: ContextColumn.Subagent) -> some View {
    let waiting = subagent.status == .permission || subagent.status == .question
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(activity(subagent)).appFont(.caption).foregroundStyle(theme.color(waiting ? .warning : .textSecondary))
        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent-activity-" + subagent.id)
      if let permission = subagent.permission {
        HStack(spacing: 6) {
          Button("Permitir") { Task { await store.reply(permission, decision: .once) } }
            .foregroundStyle(theme.color(.textStrong))
          Text("·").foregroundStyle(theme.color(.textWeak))
          Button("Negar") { Task { await store.reply(permission, decision: .reject) } }
            .foregroundStyle(theme.color(.text))
        }
        .appFont(.caption).buttonStyle(.borderless).fixedSize()
        .disabled(store.acting.contains(permission.id))
      } else if subagent.status == .question, subagent.work.sessionID != nil {
        Button("Responder ›") { open(subagent.work) }.foregroundStyle(theme.color(.textStrong))
          .appFont(.caption).buttonStyle(.borderless).fixedSize()
      }
    }
  }

  private func activity(_ subagent: ContextColumn.Subagent) -> String {
    let child = subagent.work.sessionID
    let current: String
    if let permission = subagent.permission {
      current = permission.preview
    } else if subagent.status == .question {
      current = store.family?.forms.first { $0.sessionID == child }.map { "Pergunta: " + $0.preview }
        ?? "Aguardando sua resposta"
    } else if subagent.status.live {
      current = "agora: " + (child.flatMap { progress[$0]?.current?.content } ?? child.flatMap { activities[$0] }
        ?? (subagent.status == .starting ? "iniciando" : "pensando"))
    } else {
      current = subagent.status.label.lowercased()
    }
    return ([current] + subagent.resources.map(ContextColumn.chip)).joined(separator: " · ")
  }

  /// The live subagents without a Progresso, at most eight, read their transcript tail for the current tool.
  private func loadActivities() async {
    let live = agents.filter(\.live).compactMap(\.sessionID).filter { progress[$0] == nil }.prefix(8)
    var next: [String: String] = [:]
    await withTaskGroup(of: (String, String?).self) { group in
      for child in live {
        group.addTask { [client = sessions.client] in (child, try? await client.preview(child).activity) }
      }
      for await (child, activity) in group { next[child] = activity }
    }
    guard !Task.isCancelled else { return }
    activities = next.compactMapValues { $0 }
  }

  /// The Progresso of one subagent, live while open, and "Abrir subagente".
  private func progressSheetView(_ sheet: ProgressSheet) -> some View {
    let current = sheet.work.sessionID.flatMap { progress[$0] } ?? sheet.progress
    return VStack(alignment: .leading, spacing: 10) {
      Text(sheet.work.title).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        .padding(.horizontal, 16)
      ConversationProgressList(progress: current, close: { progressSheet = nil })
      Button {
        openAfterSheet = sheet.work
        progressSheet = nil
      } label: {
        Text("Abrir subagente").appFont(.body, weight: .semibold).foregroundStyle(theme.color(.textStrong))
          .frame(maxWidth: .infinity).padding(.vertical, 13)
          .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 14))
          .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.color(.border), lineWidth: 0.7) }
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 16).padding(.bottom, 12)
      .accessibilityIdentifier("agent-progress-open")
    }
    .padding(.top, 18)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(theme.color(.background))
  }

  private func open(_ work: SessionWork) {
    if let child = work.sessionID {
      sessions.conversationPath.append(.init(id: child, parent: store.id))
      return
    }
    // A call whose child does not exist yet is in this conversation's own transcript.
    guard let tool = work.toolID else { return }
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
