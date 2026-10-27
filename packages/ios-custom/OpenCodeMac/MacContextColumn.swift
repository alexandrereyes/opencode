import AppKit
import OpenCodeKit
import SwiftUI

/// Coluna 3 at the approved "Máximo" level: neutral grays, hairlines and no cards. The only colors are the
/// diff's `+N` and `−N`, a cache hit below 80% and the `?` of a subagent asking for permission. Arquivos slides
/// over it.
struct MacContextColumn: View {
  let store: ContextColumnStore
  @Bindable var runtime: MacRuntime

  var body: some View {
    ZStack {
      if runtime.selection.files != nil {
        MacFilesView(context: store, runtime: runtime)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      } else {
        ScrollView {
          ContextColumnSections(store: store, runtime: runtime)
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)
        }
        .overlay {
          if !store.loaded { ProgressView().controlSize(.small) }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
      }
    }
    .animation(.snappy(duration: 0.25), value: runtime.selection.files == nil)
  }
}

/// Contexto top to bottom: the summary line, the three large figures, the cost line, then Subagentes,
/// Tarefas and Recursos.
struct ContextColumnSections: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  let runtime: MacRuntime

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let error = store.error {
        Label(error, systemImage: "exclamationmark.triangle").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary)).padding(.bottom, 10)
      }
      ContextSummaryLine(store: store, runtime: runtime)
      ContextFigures(store: store).padding(.top, 14).padding(.bottom, 12)
      ContextHairline()
      Text("Sessão \(ContextUsage.money(store.costs.session)) · Subagentes \(ContextUsage.money(store.costs.subagents))")
        .appFont(.caption).monospacedDigit().foregroundStyle(theme.color(.text))
        .lineLimit(1).padding(.vertical, 10)
      ContextHairline()
      ContextSubagents(store: store, runtime: runtime).padding(.top, 14)
      if !store.tasks.isEmpty {
        ContextHairline()
        ContextTasks(store: store).padding(.top, 14)
      }
      if !store.resources.isEmpty {
        ContextHairline()
        ContextResources(store: store).padding(.top, 14)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
  let runtime: MacRuntime

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

/// `US$ 78,25 | 28% | 99,5%`, each over a small gray caption, with hairlines between them.
private struct ContextFigures: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  let store: ContextColumnStore

  var body: some View {
    let usage = store.usage
    let cache = store.cacheHit
    HStack(alignment: .top, spacing: 0) {
      figure(ContextUsage.money(store.costs.total), caption: "custo total")
      divider
      figure(usage?.fraction.map(ContextUsage.percent) ?? "—",
        caption: "contexto" + (usage.map { " · " + $0.tokenLabel } ?? ""))
        .padding(.leading, 14)
      divider
      figure(cache.map(ContextColumn.percent) ?? "—", caption: "cache hit",
        tone: (cache ?? 1) < ContextColumn.cacheWarning ? .warning : .textStrong)
        .padding(.leading, 14)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Custo total \(ContextUsage.money(store.costs.total)), "
      + (usage?.accessibilityLabel ?? "contexto sem medição"))
  }

  private var divider: some View {
    Rectangle().fill(theme.color(.border)).frame(width: 1 / displayScale).padding(.vertical, 2)
  }

  private func figure(_ value: String, caption: String, tone: ThemeRole = .textStrong) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
        .foregroundStyle(theme.color(tone)).lineLimit(1).minimumScaleFactor(0.7)
      Text(caption).appFont(.footnote).monospacedDigit().foregroundStyle(theme.color(.textSecondary))
        .lineLimit(1).minimumScaleFactor(0.85)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Subagents

/// The fixed metric columns, right-aligned: contexto · cache · custo.
private enum SubagentColumns {
  static let context: CGFloat = 50
  static let cache: CGFloat = 46
  static let cost: CGFloat = 56
  static let spacing: CGFloat = 12
  static let gutter: CGFloat = 13
}

private struct ContextSubagents: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  let runtime: MacRuntime
  @State private var expanded = false

  var body: some View {
    let subagents = store.subagents
    VStack(alignment: .leading, spacing: 0) {
      ContextSectionLabel(title: "Subagentes", count: "\(subagents.active)/\(subagents.total)") {
        HStack(spacing: SubagentColumns.spacing) {
          header("contexto", width: SubagentColumns.context)
          header("cache", width: SubagentColumns.cache)
          header("custo", width: SubagentColumns.cost)
        }
      }
      .padding(.bottom, 4)
      if subagents.total == 0 {
        Text(store.loaded ? "Nenhum subagente nesta sessão." : "Carregando…").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary)).padding(.vertical, 10)
      }
      let rows = subagents.shown + (expanded ? subagents.hidden : [])
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, subagent in
        if index > 0 { ContextHairline() }
        SubagentLine(store: store, subagent: subagent) {
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

  private func header(_ title: String, width: CGFloat) -> some View {
    Text(title).appFont(.footnote).foregroundStyle(theme.color(.textSecondary))
      .frame(width: width, alignment: .trailing)
  }
}

/// One subagent: title and its metrics, `agora: …` with the resource it drives and the elapsed time, and the
/// permission's Permitir · Negar. Its state is a small glyph: a gray spinning ring while it runs, an amber `?`
/// while it asks, nothing once it ended.
private struct SubagentLine: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  let store: ContextColumnStore
  let subagent: ContextColumn.Subagent
  let open: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      glyph.frame(width: SubagentColumns.gutter, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: SubagentColumns.spacing) {
          Text(subagent.work.title).appFont(.secondary, weight: .medium).foregroundStyle(theme.color(.textStrong))
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
          metric(subagent.usage?.totalLabel ?? "—", width: SubagentColumns.context)
            .help(subagent.usage.map { $0.tokenLabel } ?? "Sem medição de contexto")
          metric(subagent.cacheHit.map(ContextColumn.percent) ?? "—", width: SubagentColumns.cache,
            tone: (subagent.cacheHit ?? 1) < ContextColumn.cacheWarning ? .warning : .text)
          metric(ContextUsage.money(subagent.cost), width: SubagentColumns.cost, tone: .textStrong)
        }
        HStack(alignment: .firstTextBaseline, spacing: SubagentColumns.spacing) {
          Text(activity).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
          Text(elapsed).appFont(.caption).monospacedDigit().foregroundStyle(theme.color(.textSecondary))
            .frame(width: SubagentColumns.cost, alignment: .trailing)
        }
        if let permission = subagent.permission {
          HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button("Permitir") { Task { await store.reply(permission, allow: true) } }
              .foregroundStyle(theme.color(.textStrong))
            Text("·").foregroundStyle(theme.color(.textWeak))
            Button("Negar") { Task { await store.reply(permission, allow: false) } }
              .foregroundStyle(theme.color(.text))
          }
          .appFont(.caption)
          .buttonStyle(.plain)
          .padding(.top, 3)
          .disabled(store.acting.contains(permission.id))
        }
      }
    }
    .padding(.vertical, 9)
    .opacity(subagent.status.live ? 1 : 0.6)
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
  }

  @ViewBuilder private var glyph: some View {
    switch subagent.status {
    case .permission, .question:
      Image(systemName: "questionmark.circle").font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.color(.warning))
        .accessibilityLabel(subagent.status.label)
    case .running, .starting:
      ContextSpinner().accessibilityLabel(subagent.status.label)
    default:
      Color.clear.frame(width: 11, height: 11)
    }
  }

  private func metric(_ value: String, width: CGFloat, tone: ThemeRole = .text) -> some View {
    Text(value).appFont(.footnote).monospacedDigit().foregroundStyle(theme.color(tone)).lineLimit(1)
      .frame(width: width, alignment: .trailing)
  }

  /// `agora: usando webfetch · Chrome · localhost:4177`: the current tool, then any resource it drives.
  private var activity: String {
    let current: String
    if let permission = subagent.permission {
      current = permission.preview
    } else if subagent.status == .question {
      current = "aguardando sua resposta"
    } else if subagent.status.live {
      current = subagent.work.sessionID.flatMap { store.activities[$0] } ?? "pensando"
    } else {
      current = subagent.status.label.lowercased()
    }
    let resources = subagent.resources.map(ContextColumn.chip)
    return ([(subagent.status.live ? "agora: " : "") + current] + resources).joined(separator: " · ")
  }

  private var elapsed: String {
    let millis = now.timeIntervalSince1970 * 1000
    if subagent.status.live { return SessionList.relativeTime(subagent.work.started, now: now).label }
    return subagent.work.duration.map { SessionList.relativeTime(millis - $0, now: now).label } ?? "—"
  }
}

/// A small gray ring turning while a subagent runs.
private struct ContextSpinner: View {
  @Environment(\.appTheme) private var theme
  @State private var turning = false
  var body: some View {
    Circle().trim(from: 0, to: 0.72)
      .stroke(theme.color(.textSecondary), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      .frame(width: 10, height: 10)
      .rotationEffect(.degrees(turning ? 360 : 0))
      .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
      .onAppear { turning = true }
  }
}

// MARK: - Background tasks

private struct ContextTasks: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
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
    return ContextListRow(
      icon: taskSymbol(task.title),
      title: label.command + (label.port.map { " · :" + String($0) } ?? ""),
      state: task.running ? SessionList.relativeTime(task.started, now: now).label : task.state.label,
      dimmed: !task.running)
    .opacity(store.acting.contains(task.id) ? 0.5 : 1)
    .contextMenu {
      if task.running {
        Button("Parar", systemImage: "stop.fill", role: .destructive) { Task { await store.stop(task) } }
      }
      Button("Copiar comando", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.title, forType: .string)
      }
    }
    .help(task.title)
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

// MARK: - Resources

private struct ContextResources: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.sessionRowDate) private var now
  let store: ContextColumnStore

  var body: some View {
    let split = ContextColumn.resources(store.resources)
    let resources = split.inUse + split.others
    VStack(alignment: .leading, spacing: 0) {
      ContextSectionLabel(title: "Recursos", count: "\(resources.count)").padding(.bottom, 4)
      ForEach(Array(resources.enumerated()), id: \.element.id) { index, resource in
        if index > 0 { ContextHairline() }
        Button { openWindow(id: "resource", value: resource.id) } label: {
          ContextListRow(icon: resourceSymbol(resource.kind), title: name(resource), state: state(resource),
            dimmed: !resource.state.running)
        }
        .buttonStyle(.plain)
        .help("Abrir \(ContextColumn.title(resource))")
        .contextMenu {
          Button("Abrir", systemImage: "macwindow") { openWindow(id: "resource", value: resource.id) }
          if !resource.state.running {
            Button("Remover da lista", systemImage: "xmark.circle", role: .destructive) {
              Task { await store.dismiss(resource) }
            }
          }
        }
      }
    }
  }

  /// The simulated device on its own (the icon says it is an iPhone); the kind and name otherwise.
  private func name(_ resource: SessionResource) -> String {
    resource.kind == .iosSimulator ? ContextColumn.name(resource) : ContextColumn.title(resource)
  }

  /// "Agente usando", "Você no controle", "Livre", "Parado há 8 min".
  private func state(_ resource: SessionResource) -> String {
    guard !resource.state.running else { return resource.state.label }
    let at = resource.updatedAt > 0 ? resource.updatedAt : resource.lastUsedAt
    return at > 0 ? "Parado " + ContextColumn.ago(at, now: now) : "Parado"
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
