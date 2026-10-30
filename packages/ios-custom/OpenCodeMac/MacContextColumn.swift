import AppKit
import OpenCodeKit
import SwiftUI

/// Coluna 3 at the approved "Máximo" level: neutral grays, hairlines and no cards. The only colors are the
/// diff's `+N` and `−N`, a cache hit below 80% and the `?` of a subagent asking for permission. Arquivos replaces
/// it in place, with no animation (a slide used to run past the window's edge).
struct MacContextColumn: View {
  let store: ContextColumnStore
  @Bindable var runtime: MacWindowRuntime

  var body: some View {
    #if DEBUG
    let _ = MacPerf.count("MacContextColumn")
    #endif
    if runtime.selection.files != nil {
      MacFilesView(context: store, runtime: runtime)
    } else {
      ScrollView {
        ContextColumnSections(store: store, runtime: runtime)
          .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)
          .macThinScrollers()
      }
      // On macOS 26 the scroll view reaches under the title bar, where its rows mixed with the bar's items: cut
      // it at the bar's bottom edge, like the chat's transcript.
      .clipped()
      .overlay {
        if !store.loaded { ProgressView().controlSize(.small) }
      }
    }
  }
}

/// Contexto top to bottom, for the session open in the middle column (the root or a subagent over it): the path
/// back to the root when it is a subagent, the summary line, the session's metrics line, the cost line, then
/// Subagentes, MCPs, Tarefas and Recursos.
struct ContextColumnSections: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  let runtime: MacWindowRuntime
  @State private var narrow = false

  var body: some View {
    #if DEBUG
    let _ = MacPerf.count("ContextColumnSections")
    #endif
    VStack(alignment: .leading, spacing: 0) {
      if let error = store.error {
        Label(error, systemImage: "exclamationmark.triangle").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary)).padding(.bottom, 10)
      }
      if let root = runtime.selection.sessionID, root != store.id {
        ContextSessionPath(store: store, runtime: runtime, rootID: root).padding(.bottom, 10)
      }
      ContextSummaryLine(store: store, runtime: runtime)
      ContextFigures(store: store).padding(.top, 12).padding(.bottom, 12)
      ContextHairline()
      Text("Sessão \(ContextUsage.money(store.costs.session)) · Subagentes \(ContextUsage.money(store.costs.subagents))")
        .appFont(.caption).monospacedDigit().foregroundStyle(theme.color(.text))
        .lineLimit(1).padding(.vertical, 10)
      ContextHairline()
      ContextSubagents(store: store, runtime: runtime, narrow: narrow).padding(.top, 14)
      if let mcps = store.sessions.liveConversation(store.id)?.mcps, mcps.summary.visible {
        ContextHairline()
        ContextMCPs(store: mcps).padding(.top, 14)
      }
      if !store.tasks.isEmpty {
        ContextHairline()
        ContextTasks(store: store).padding(.top, 14)
      }
      if !store.resources.isEmpty {
        ContextHairline()
        MacResourcesSection(store: store, runtime: runtime).padding(.top, 14)
      }
      ContextHairline()
      ContextDetails(store: store, runtime: runtime).padding(.top, 14)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Only crossing the width changes the state, so dragging the divider re-renders nothing else.
    .onGeometryChange(for: Bool.self) { $0.size.width < ContextColumn.narrowWidth } action: {
      narrow = $0
      #if DEBUG
      MacContextProbe.narrow = $0
      #endif
    }
  }
}

#if DEBUG
/// What the column decided, for `MacAjustesChecks`: its background test copy has no accessibility tree to read.
@MainActor enum MacContextProbe {
  static var narrow = false
}
#endif

/// `App Mac › Backend da Live Activity`: the column follows the subagent open in the middle column. Each ancestor
/// goes back to itself; the root clears the subagent, like ⌘[ from its direct child.
private struct ContextSessionPath: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  let runtime: MacWindowRuntime
  let rootID: String

  var body: some View {
    let path = store.sessions.subagentPath(root: rootID, child: store.id)
    let rootTitle = store.sessions.liveConversation(rootID)?.session?.displayTitle
      ?? store.sessions.entries.first { $0.session.id == rootID }?.session.displayTitle ?? "Sessão principal"
    let ancestors = [(id: rootID, title: rootTitle)] + path.dropLast().map { (id: $0.id, title: $0.displayTitle) }
    HStack(spacing: 5) {
      ForEach(Array(ancestors.enumerated()), id: \.offset) { index, ancestor in
        Button {
          runtime.open(ancestor: ancestor.id)
        } label: {
          Text(ancestor.title).lineLimit(1).truncationMode(.middle).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary))
        .help("Voltar para \(ancestor.title)" + (index == ancestors.count - 1 ? " (⌘[)" : ""))
        .accessibilityIdentifier("context-path-" + ancestor.id)
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
          .foregroundStyle(theme.color(.textWeak)).accessibilityHidden(true)
      }
      Text(store.session?.displayTitle ?? path.last?.displayTitle ?? "Subagente")
        .foregroundStyle(theme.color(.text)).lineLimit(1).layoutPriority(1)
      Spacer(minLength: 0)
    }
    .appFont(.caption)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("context-path")
  }
}

/// A thin neutral rule between the column's parts.
struct ContextHairline: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    Rectangle().fill(theme.color(.border)).frame(height: 1 / displayScale).accessibilityHidden(true)
  }
}

/// `SUBAGENTES  4/46`: small capitals with letter spacing, then the count.
struct ContextSectionLabel<Trailing: View>: View {
  @Environment(\.appTheme) private var theme
  let title: String
  let count: String
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(alignment: .lastTextBaseline, spacing: 8) {
      Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.9)
      Text(count).font(.system(size: 11, weight: .medium)).monospacedDigit()
      Spacer(minLength: 8)
      trailing()
    }
    .foregroundStyle(theme.color(.text))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

extension ContextSectionLabel where Trailing == EmptyView {
  init(title: String, count: String) { self.init(title: title, count: count) { EmptyView() } }
}

// MARK: - Summary and figures

/// `mac-app · +128 −14 · Arquivos ›`. The branch's menu copies it or the path, or shows it in the Finder.
private struct ContextSummaryLine: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  let runtime: MacWindowRuntime

  private var label: SessionDirectoryLabel? { store.session.flatMap { store.sessions.directoryLabel($0) } }
  private var branch: String? { label?.branch ?? store.located?.branch }

  var body: some View {
    let summary = store.summary
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(branch ?? "—").foregroundStyle(theme.color(.textStrong)).lineLimit(1)
        .help(label?.path ?? store.directory ?? "")
        .contextMenu {
          if let branch { Button("Copiar branch") { copy(branch) } }
          if let directory = store.directory {
            Button("Copiar caminho") { copy(directory) }
            if FileManager.default.fileExists(atPath: directory) {
              Button("Mostrar no Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory) }
            }
          }
        }
      Text("·").foregroundStyle(theme.color(.textWeak))
      HStack(spacing: 5) {
        Text("+\(summary.additions)").foregroundStyle(theme.color(.success))
        Text("−\(summary.deletions)").foregroundStyle(theme.color(.error))
      }
      .monospacedDigit().fixedSize()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(summary.additions) linhas adicionadas, \(summary.deletions) removidas, \(summary.files) arquivos")
      .help(summary.files == 1 ? "1 arquivo alterado" : "\(summary.files) arquivos alterados")
      Text("·").foregroundStyle(theme.color(.textWeak))
      Button { runtime.showFiles() } label: {
        HStack(spacing: 3) {
          Text("Arquivos")
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(theme.color(.text)).contentShape(Rectangle())
      }
      .buttonStyle(.plain).fixedSize()
      .help("Arquivos da sessão (⇧⌘F)")
      Spacer(minLength: 0)
    }
    .appFont(.secondary)
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

/// `◔ 38% 383,2k / 1M · ⚡ 97,8% cache · US$ 42,77 total`: the session's context (its latest measured step), cache hit
/// and total cost, in the subagent lines' order and format at a larger size. It breaks after the context when the
/// column is too narrow for one line.
private struct ContextFigures: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore

  var body: some View {
    let usage = store.usage
    let metrics = ContextColumn.metrics(usage: usage, cacheHit: store.cacheHit, cost: store.costs.total)
    let context = metrics.filter { $0.kind == .context || $0.kind == .tokens }
    let rest = metrics.filter { $0.kind != .context && $0.kind != .tokens }
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 9) {
        group(context, usage: usage)
        if !context.isEmpty && !rest.isEmpty { separator }
        others(rest)
      }
      VStack(alignment: .leading, spacing: 6) {
        group(context, usage: usage)
        HStack(alignment: .center, spacing: 9) { others(rest) }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel((usage?.accessibilityLabel ?? "contexto sem medição")
      + ", custo total \(ContextUsage.money(store.costs.total))")
  }

  private var separator: some View { Text("·").font(.system(size: 15)).foregroundStyle(theme.color(.textWeak)) }

  /// `◔ 38% 383,2k / 1M`, or `383,2k tokens` for a model outside the catalog.
  @ViewBuilder private func group(_ metrics: [ContextColumn.Metric], usage: ContextUsage?) -> some View {
    if !metrics.isEmpty {
      HStack(alignment: .center, spacing: 7) {
        if let usage, metrics.contains(where: { $0.kind == .context }) { ContextUsageRing(usage: usage, size: 17) }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          ForEach(metrics, id: \.kind) { metric in
            if metric.kind == .context || metrics.count == 1 {
              value(metric.text)
            } else {
              caption(metric.text)
            }
          }
        }
      }
    }
  }

  /// `⚡ 97,8% cache · US$ 42,77 total`.
  @ViewBuilder private func others(_ metrics: [ContextColumn.Metric]) -> some View {
    ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
      if index > 0 { separator }
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        if metric.kind == .cache {
          Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(theme.color(.textSecondary))
        }
        value(metric.text, tone: metric.warning ? .warning : .textStrong)
        caption(metric.kind == .cache ? "cache" : "total")
      }
    }
  }

  private func value(_ text: String, tone: ThemeRole = .textStrong) -> some View {
    Text(text).font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundStyle(theme.color(tone))
      .lineLimit(1)
  }

  private func caption(_ text: String) -> some View {
    Text(text).appFont(.caption).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
  }
}

// MARK: - Subagents

private struct ContextSubagents: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  let runtime: MacWindowRuntime
  let narrow: Bool
  @State private var expanded = false

  var body: some View {
    #if DEBUG
    let _ = MacPerf.count("ContextSubagents")
    #endif
    let subagents = store.subagents
    VStack(alignment: .leading, spacing: 0) {
      ContextSectionLabel(title: "Subagentes", count: "\(subagents.active)/\(subagents.total)")
        .padding(.bottom, 4)
      if subagents.total == 0 {
        Text(store.loaded ? "Nenhum subagente nesta sessão." : "Carregando…").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary)).padding(.vertical, 10)
      }
      let rows = subagents.shown + (expanded ? subagents.hidden : [])
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, subagent in
        if index > 0 { ContextHairline() }
        SubagentLine(store: store, subagent: subagent, narrow: narrow) {
          if let child = subagent.work.sessionID { runtime.selection.childID = child }
        }
      }
      if !subagents.hidden.isEmpty {
        ContextHairline()
        Button {
          withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
          HStack {
            Text(expanded ? "Ocultar concluídos" : "+\(subagents.hidden.count) concluídos")
            Spacer()
            Image(systemName: expanded ? "chevron.up" : "chevron.right").font(.system(size: 10, weight: .semibold))
              .foregroundStyle(theme.color(.icon))
          }
          .appFont(.secondary).foregroundStyle(theme.color(.text))
          .padding(.vertical, 10)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

/// One subagent, aligned at the column's margin with no glyph before it: the title, `agente · Modelo · esforço`, the
/// metrics line and `agora: …` with the resource it drives. A running title shimmers like the web's; one waiting for
/// Alexandre carries an amber `?` after it and says what it asks, in amber, beside Permitir · Negar or Responder;
/// a finished row is dimmed to 45%, below a running title's dimmer base between passes.
private struct SubagentLine: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.macStillCapture) private var still
  let store: ContextColumnStore
  let subagent: ContextColumn.Subagent
  let narrow: Bool
  let open: () -> Void

  private var waiting: Bool { subagent.status == .permission || subagent.status == .question }

  var body: some View {
    #if DEBUG
    let _ = MacPerf.count("SubagentLine")
    #endif
    VStack(alignment: .leading, spacing: 3) {
      title
      // `astraxhighultra · Astra 6 - ultrafast · xhigh`: who runs it and with which model now.
      Text(ContextColumn.runLabel(subagent.work, agents: store.agents, models: store.models) ?? "—")
        .appFont(.footnote).foregroundStyle(theme.color(.textSecondary))
        .lineLimit(1).truncationMode(.middle)
        .accessibilityIdentifier("subagent-model-" + subagent.id)
      metrics
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(activity).appFont(.caption).foregroundStyle(theme.color(waiting ? .warning : .textSecondary))
          .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        actions
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 9)
    .opacity(subagent.status.live ? 1 : 0.45)
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .contextMenu {
      if subagent.work.sessionID != nil { Button("Abrir subagente", systemImage: "bubble.left", action: open) }
      if subagent.work.running {
        Button("Parar", systemImage: "stop.fill", role: .destructive) { Task { await store.stop(subagent.work) } }
      }
    }
    .help(subagent.work.sessionID == nil ? "" : "Abrir \(subagent.work.title)")
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(subagent.work.title), \(subagent.status.label)")
    .accessibilityIdentifier("subagent-" + subagent.id)
  }

  @ViewBuilder private var title: some View {
    let text = subagent.work.title
    if waiting {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        plainTitle(text)
        Image(systemName: "questionmark.circle").font(.system(size: 12, weight: .medium))
          .foregroundStyle(theme.color(.warning)).fixedSize()
          .accessibilityLabel(subagent.status.label)
      }
    } else if (subagent.status == .running || subagent.status == .starting) && !reduceMotion && !still {
      MacShimmerText(text: text, font: .systemFont(ofSize: AppTextStyle.secondary.size, weight: .medium),
        base: theme.nsColor(.textSecondary), peak: theme.nsColor(.textStrong))
        .accessibilityLabel(text)
        .accessibilityIdentifier("subagent-shimmer-" + subagent.id)
    } else {
      plainTitle(text)
    }
  }

  private func plainTitle(_ text: String) -> some View {
    Text(text).appFont(.secondary, weight: .medium).foregroundStyle(theme.color(.textStrong)).lineLimit(1)
  }

  /// The tokens drop first when the line does not fit (narrow, or a long cost); they stay in the tooltip.
  private var metrics: some View {
    let line = { (narrow: Bool) in
      ContextMetricsLine(
        metrics: ContextColumn.metrics(usage: subagent.usage, cacheHit: subagent.cacheHit, cost: subagent.cost,
          elapsed: elapsed, progress: subagent.progress, narrow: narrow),
        usage: subagent.usage)
    }
    return ViewThatFits(in: .horizontal) {
      line(narrow)
      line(true)
    }
    .help(subagent.usage.map { "Contexto \($0.tokenLabel)" } ?? "Sem medição de contexto")
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("subagent-metrics-" + subagent.id)
  }

  @ViewBuilder private var actions: some View {
    if let permission = subagent.permission {
      HStack(spacing: 6) {
        Button("Permitir") { Task { await store.reply(permission, allow: true) } }
          .foregroundStyle(theme.color(.textStrong))
        Text("·").foregroundStyle(theme.color(.textWeak))
        Button("Negar") { Task { await store.reply(permission, allow: false) } }
          .foregroundStyle(theme.color(.text))
      }
      .appFont(.caption).buttonStyle(.plain).fixedSize()
      .disabled(store.acting.contains(permission.id))
    } else if subagent.status == .question, subagent.work.sessionID != nil {
      Button("Responder ›", action: open).foregroundStyle(theme.color(.textStrong))
        .appFont(.caption).buttonStyle(.plain).fixedSize()
    }
  }

  /// `agora: usando webfetch · Chrome · localhost:4177`: the current tool, then any resource it drives. A request
  /// says what it asks for instead (`Quer rodar: gh api …`, `Pergunta: …`).
  private var activity: String {
    let current: String
    if let permission = subagent.permission {
      current = permission.preview
    } else if subagent.status == .question {
      current = store.question(subagent.work.sessionID).map { "Pergunta: " + $0.preview } ?? "Aguardando sua resposta"
    } else if subagent.status.live {
      current = "agora: " + (subagent.work.sessionID.flatMap { store.activities[$0] } ?? "pensando")
    } else {
      current = subagent.status.label.lowercased()
    }
    return ([current] + subagent.resources.map(ContextColumn.chip)).joined(separator: " · ")
  }

  private var elapsed: String? {
    let millis = now.timeIntervalSince1970 * 1000
    if subagent.status.live { return SessionList.relativeTime(subagent.work.started, now: now).label }
    return subagent.work.duration.map { SessionList.relativeTime(millis - $0, now: now).label }
  }
}

/// `◔ 71% · 711,3k / 1M · ⚡ 99,0% · US$ 26,95 · 20m · ☑ 2/4`, in the order `ContextColumn.metrics` gives.
private struct ContextMetricsLine: View {
  @Environment(\.appTheme) private var theme
  let metrics: [ContextColumn.Metric]
  let usage: ContextUsage?

  var body: some View {
    HStack(alignment: .center, spacing: 5) {
      ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
        if index > 0 { Text("·").foregroundStyle(theme.color(.textWeak)) }
        item(metric)
      }
    }
    .appFont(.footnote).monospacedDigit().lineLimit(1)
  }

  @ViewBuilder private func item(_ metric: ContextColumn.Metric) -> some View {
    switch metric.kind {
    case .context:
      HStack(spacing: 4) {
        if let usage { ContextUsageRing(usage: usage, size: 10) }
        Text(metric.text).foregroundStyle(theme.color(.text))
      }
    case .cache:
      HStack(spacing: 2) {
        Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(theme.color(.textSecondary))
        Text(metric.text).foregroundStyle(theme.color(metric.warning ? .warning : .text))
      }
    case .progress:
      HStack(spacing: 3) {
        Image(systemName: "checklist").font(.system(size: 9)).foregroundStyle(theme.color(.textSecondary))
        Text(metric.text).foregroundStyle(theme.color(.text))
      }
      .accessibilityLabel("Progresso \(metric.text)")
    case .cost: Text(metric.text).foregroundStyle(theme.color(.textStrong))
    case .tokens, .elapsed: Text(metric.text).foregroundStyle(theme.color(.textSecondary))
    }
  }
}

// MARK: - MCPs

/// `MCPS  1/4`: the conversation's MCP servers with a switch each, on the composer panel's store, routes, order
/// and rules (`ConversationMCPStore`): a server needing login sends to the web, a pending one waits.
private struct ContextMCPs: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationMCPStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ContextSectionLabel(title: "MCPs", count: "\(store.summary.connected)/\(store.summary.total)").padding(.bottom, 4)
      if store.failed && !store.loading {
        Button("Não foi possível carregar · Tentar novamente") { Task { await store.refresh() } }
          .buttonStyle(.plain).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).padding(.vertical, 8)
      }
      ForEach(Array(store.chips.enumerated()), id: \.element.name) { index, server in
        if index > 0 { ContextHairline() }
        row(server)
      }
    }
  }

  private func row(_ server: MCPServer) -> some View {
    let state = server.status.status
    // Switch first: the state reads at the start of the row, where the eye lands.
    return HStack(spacing: 10) {
      ZStack {
        if state == .pending {
          ProgressView().controlSize(.mini)
        } else {
          Toggle(server.name, isOn: Binding(get: { state == .connected }, set: { _ in Task { await store.toggle(server) } }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            .disabled(state == .unknown)
        }
      }
      .frame(width: 30)
      Text(server.name).appFont(.caption)
        .foregroundStyle(theme.color(state == .connected ? .textStrong : .textSecondary))
        .lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 8)
      if let label = label(server) {
        Text(label).appFont(.caption).foregroundStyle(theme.color(state == .failed ? .error : .textSecondary))
          .lineLimit(1).truncationMode(.tail).help(server.status.error ?? label)
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }

  private func label(_ server: MCPServer) -> String? {
    switch server.status.status {
    case .connected: "conectado"
    case .needsAuth: "exige login no web"
    case .failed: server.status.error ?? "falhou"
    case .unknown: "indisponível"
    case .disabled, .pending: nil
    }
  }
}

// MARK: - Background tasks

private struct ContextTasks: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  @Environment(\.openWindow) private var openWindow
  let store: ContextColumnStore

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ContextSectionLabel(title: "Tarefas", count: "\(store.tasks.count)").padding(.bottom, 4)
      ForEach(Array(store.tasks.enumerated()), id: \.element.id) { index, task in
        if index > 0 { ContextHairline() }
        row(task)
      }
    }
  }

  private func row(_ task: SessionWork) -> some View {
    let label = ContextColumn.task(task.title)
    return Button { output(task) } label: {
      ContextListRow(
        icon: taskSymbol(task.title),
        title: label.command + (label.port.map { " · :" + String($0) } ?? ""),
        state: task.running ? SessionList.relativeTime(task.started, now: now).label : task.state.label,
        dimmed: !task.running)
    }
    .buttonStyle(.plain)
    .opacity(store.acting.contains(task.id) ? 0.5 : 1)
    .contextMenu {
      Button("Ver saída", systemImage: "text.alignleft") { output(task) }.disabled(task.shellID == nil)
      if task.running {
        Button("Parar", systemImage: "stop.fill", role: .destructive) { Task { await store.stop(task) } }
      }
      Button("Copiar comando", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.title, forType: .string)
      }
    }
    .help(task.title + " · clique para ver a saída")
  }

  /// The task's live output in its own window.
  private func output(_ task: SessionWork) {
    guard let shell = task.shellID, let directory = store.directory else { return }
    openWindow(id: MacShellOutputWindow.id,
      value: MacShellOutputWindow.Target(shellID: shell, directory: directory, command: task.title))
  }

  /// A build or test reads as a hammer; anything else (a dev server, a script) as running.
  private func taskSymbol(_ command: String) -> String {
    command.range(of: #"\b(build|test|xcodebuild|swift test|check|lint)\b"#, options: .regularExpression) != nil
      ? "hammer" : "play"
  }
}

/// A task or resource line: a small monochrome icon, the name and its state in gray at the end.
private struct ContextListRow: View {
  @Environment(\.appTheme) private var theme
  let icon: String
  let title: String
  let state: String
  var dimmed = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon).font(.system(size: 13)).foregroundStyle(theme.color(.icon))
        .frame(width: 18).accessibilityHidden(true)
      Text(title).appFont(.caption).foregroundStyle(theme.color(dimmed ? .textSecondary : .text))
        .lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 8)
      Text(state).appFont(.caption).monospacedDigit().foregroundStyle(theme.color(.textSecondary))
        .lineLimit(1).fixedSize()
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }
}

// MARK: - Details

/// The iPhone's Detalhes da sessão at the column's foot, closed by default: model and agent, the working
/// directory (opens Arquivos), the skills the session loaded and the plugins. MCPs have their own section above.
private struct ContextDetails: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: ContextColumnStore
  let runtime: MacWindowRuntime
  @State private var allSkills = false
  @State private var allPlugins = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy(duration: 0.2)) { store.detailsOpen.toggle() }
      } label: {
        ContextSectionLabel(title: "Detalhes", count: "") {
          Image(systemName: store.detailsOpen ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.color(.icon))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.bottom, store.detailsOpen ? 6 : 14)
      .help(store.detailsOpen ? "Ocultar detalhes da sessão" : "Modelo, diretório, skills e plugins")
      if store.detailsOpen { details.padding(.bottom, 14) }
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 10) {
      line("Modelo", modelLabel)
      line("Agente", store.session?.agent ?? "—")
      if let directory = store.directory {
        HStack(alignment: .firstTextBaseline) {
          Text("Diretório").foregroundStyle(theme.color(.textSecondary)).frame(width: 74, alignment: .leading)
          Button { runtime.showFiles() } label: {
            Text(directory).foregroundStyle(theme.color(.text)).lineLimit(2).truncationMode(.middle)
              .multilineTextAlignment(.leading)
          }
          .buttonStyle(.plain)
          .help("Abrir em Arquivos")
          .contextMenu {
            Button("Copiar caminho") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(directory, forType: .string)
            }
            if FileManager.default.fileExists(atPath: directory) {
              Button("Mostrar no Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory) }
            }
          }
          Spacer(minLength: 0)
        }
      }
      ContextHairline()
      subheading("Skills", count: store.services?.skills?.count)
      list(store.services.map { $0.skills?.map(\.name) }, all: $allSkills, empty: "Nenhuma skill carregada")
      ContextHairline()
      subheading("Plugins", count: store.services?.plugins?.count)
      list(store.services.map { $0.plugins?.map { $0.id + " · " + $0.label } }, all: $allPlugins,
        empty: "Nenhum configurado")
    }
    .appFont(.caption)
  }

  private var modelLabel: String {
    guard let model = store.session?.model else { return "—" }
    let name = store.models.first { $0.id == model.id && $0.providerID == model.providerID }?.name ?? model.id
    return [name, model.variant].compactMap { $0 }.joined(separator: " · ")
  }

  private func line(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(theme.color(.textSecondary)).frame(width: 74, alignment: .leading)
      Text(value).foregroundStyle(theme.color(.text)).lineLimit(1).textSelection(.enabled)
      Spacer(minLength: 0)
    }
  }

  private func subheading(_ title: String, count: Int?) -> some View {
    HStack(spacing: 6) {
      Text(title).fontWeight(.semibold).foregroundStyle(theme.color(.text))
      if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(theme.color(.textSecondary)) }
    }
  }

  private func muted(_ text: String) -> some View {
    Text(text).foregroundStyle(theme.color(.textSecondary))
  }

  /// The first five rows, then "Mostrar todos (N)", like the iPhone's collapsed sections.
  @ViewBuilder private func list(_ items: [String]??, all: Binding<Bool>, empty: String) -> some View {
    switch items {
    case .none: muted("Carregando…")
    case .some(.none): muted("Indisponível")
    case .some(.some(let items)):
      if items.isEmpty { muted(empty) }
      ForEach(Array((all.wrappedValue ? items : Array(items.prefix(5))).enumerated()), id: \.offset) { _, item in
        Text(item).foregroundStyle(theme.color(.text)).lineLimit(1).truncationMode(.middle)
      }
      if items.count > 5 {
        Button(all.wrappedValue ? "Mostrar menos" : "Mostrar todos (\(items.count))") { all.wrappedValue.toggle() }
          .buttonStyle(.plain).foregroundStyle(theme.color(.textAccent))
      }
    }
  }
}

func resourceSymbol(_ kind: ResourceKind) -> String {
  switch kind {
  case .iosSimulator: "iphone"
  case .androidEmulator: "candybarphone"
  case .chrome: "globe"
  case .unknown: "display"
  }
}
