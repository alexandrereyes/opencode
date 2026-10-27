import AppKit
import OpenCodeKit
import SwiftUI

/// Coluna 3, opção 3 (no tabs): the checkout and cost header, subagents, background tasks and live resources.
/// Arquivos slides over it.
struct MacContextColumn: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  @Bindable var runtime: MacRuntime

  var body: some View {
    ZStack {
      if runtime.selection.files != nil {
        MacFilesView(context: store, runtime: runtime)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      } else {
        ScrollView {
          ContextColumnCards(store: store, runtime: runtime).padding(12)
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

/// The sections of Contexto, top to bottom.
struct ContextColumnCards: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  let runtime: MacRuntime
  var body: some View {
    VStack(spacing: 12) {
      if let error = store.error {
        Label(error, systemImage: "exclamationmark.triangle").appFont(.caption)
          .foregroundStyle(theme.color(.error)).frame(maxWidth: .infinity, alignment: .leading)
      }
      ContextHeaderCard(store: store, runtime: runtime)
      SubagentsCard(store: store, runtime: runtime)
      if !store.tasks.isEmpty { TasksCard(store: store) }
      if !store.resources.isEmpty { ResourcesCard(store: store) }
    }
  }
}

/// The column's cards: a raised surface with a hairline border.
struct ContextCard<Content: View>: View {
  @Environment(\.appTheme) private var theme
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 14))
      .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.color(.border), lineWidth: 1) }
  }
}

/// "Subagentes 46 · 4 ativos": the title, a count capsule and a trailing note.
struct ContextSectionTitle: View {
  @Environment(\.appTheme) private var theme
  let icon: String
  let title: String
  let count: Int
  var note: String? = nil
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon).appSymbol(.inline).foregroundStyle(theme.color(.text)).frame(width: 18)
      Text(title).appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
      Text("\(count)").appFont(.caption, weight: .medium).monospacedDigit()
        .padding(.horizontal, 7).padding(.vertical, 1.5)
        .background(theme.color(.highlight), in: Capsule())
        .foregroundStyle(theme.color(.text))
      if let note { Text("· " + note).appFont(.secondary).foregroundStyle(theme.color(.textSecondary)) }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - Header

private struct ContextHeaderCard: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  let runtime: MacRuntime

  private var label: SessionDirectoryLabel? { store.session.flatMap { store.sessions.directoryLabel($0) } }
  private var branch: String? { label?.branch ?? store.located?.branch }

  var body: some View {
    ContextCard {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "arrow.triangle.branch").appSymbol(.action).foregroundStyle(theme.color(.text))
          .frame(width: 22).padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          Menu {
            if let branch { Button("Copiar branch") { copy(branch) } }
            if let directory = store.directory {
              Button("Copiar caminho") { copy(directory) }
              if FileManager.default.fileExists(atPath: directory) {
                Button("Mostrar no Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory) }
              }
            }
          } label: {
            HStack(spacing: 5) {
              Text(branch ?? "—").appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
              Image(systemName: "chevron.down").appSymbol(.disclosure, weight: .semibold)
                .foregroundStyle(theme.color(.textSecondary))
            }
          }
          .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
          Text(label?.path ?? store.directory ?? "—").appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
            .lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 8)
        HStack(alignment: .center, spacing: 10) {
          changes
          Button { runtime.showFiles() } label: {
            HStack(spacing: 6) {
              Image(systemName: "folder")
              Text("Arquivos")
              Image(systemName: "chevron.right").appSymbol(.disclosure, weight: .semibold)
            }
            .appFont(.secondary, weight: .medium)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(theme.color(.surfaceRaised), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border), lineWidth: 1) }
          }
          .buttonStyle(.plain).foregroundStyle(theme.color(.textStrong)).fixedSize()
          .help("Arquivos da sessão (⇧⌘F)")
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .bottom, spacing: 16) {
          usage
          Spacer(minLength: 0)
          costs(alignment: .trailing)
        }
        VStack(alignment: .leading, spacing: 8) {
          usage
          costs(alignment: .leading)
        }
      }
      .padding(.top, 12)
    }
  }

  private var changes: some View {
    let summary = store.summary
    return HStack(spacing: 4) {
      Text("+\(summary.additions)").foregroundStyle(theme.color(.success))
      Text("−\(summary.deletions)").foregroundStyle(theme.color(.error))
      Text("· \(summary.files) \(summary.files == 1 ? "arquivo" : "arquivos")").foregroundStyle(theme.color(.textSecondary))
    }
    .appFont(.secondary).monospacedDigit().fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(summary.additions) linhas adicionadas, \(summary.deletions) removidas, \(summary.files) arquivos")
  }

  private var usage: some View {
    let usage = store.usage
    let cache = store.cacheHit
    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 5) {
        Text(usage?.contextLabel ?? "Contexto —").foregroundStyle(theme.color(.textStrong))
        if let usage { Text("· " + usage.tokenLabel) }
        Text("·")
        Image(systemName: "bolt.fill").foregroundStyle(theme.color(cacheRole(cache)))
        Text("Cache hit " + (cache.map(ContextColumn.percent) ?? "—"))
        Text("·")
        Text(ContextUsage.money(store.costs.total)).fontWeight(.semibold).foregroundStyle(theme.color(.textStrong))
      }
      .appFont(.secondary).monospacedDigit().foregroundStyle(theme.color(.text)).lineLimit(1).fixedSize()
      Capsule().fill(theme.color(.contextTrack)).frame(height: 7)
        .overlay(alignment: .leading) {
          GeometryReader { geometry in
            Capsule().fill(theme.color(usage?.warning == true ? .contextWarning : .primary))
              .frame(width: geometry.size.width * (usage?.drawnFraction ?? 0))
          }
        }
        .frame(maxWidth: 420)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel((usage?.accessibilityLabel ?? "Contexto sem medição") + ", custo total "
      + ContextUsage.money(store.costs.total))
  }

  private func costs(alignment: HorizontalAlignment) -> some View {
    VStack(alignment: alignment, spacing: 3) {
      Text("Sessão " + ContextUsage.money(store.costs.session))
      Text("Subagentes " + ContextUsage.money(store.costs.subagents))
    }
    .appFont(.caption).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).fixedSize()
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

func cacheRole(_ value: Double?) -> ThemeRole {
  guard let value else { return .textSecondary }
  return value < ContextColumn.cacheWarning ? .warning : .primary
}

// MARK: - Subagents

private struct SubagentsCard: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore
  let runtime: MacRuntime
  @State private var expanded = false

  var body: some View {
    let subagents = store.subagents
    ContextCard {
      ContextSectionTitle(
        icon: "person.3.fill", title: "Subagentes", count: subagents.total,
        note: subagents.active == 1 ? "1 ativo" : "\(subagents.active) ativos")
        .padding(.bottom, 6)
      if subagents.total == 0 {
        Text(store.loaded ? "Nenhum subagente nesta sessão." : "Carregando…").appFont(.secondary)
          .foregroundStyle(theme.color(.textSecondary)).padding(.vertical, 8)
      }
      let rows = subagents.shown + (expanded ? subagents.hidden : [])
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, subagent in
        if index > 0 { Divider().overlay(theme.color(.border)) }
        SubagentRow(store: store, subagent: subagent) {
          if let child = subagent.work.sessionID { runtime.selection.childID = child }
        }
      }
      if !subagents.hidden.isEmpty {
        Divider().overlay(theme.color(.border))
        Button {
          withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
          HStack {
            Text(expanded ? "Ocultar concluídos" : "+\(subagents.hidden.count) concluídos")
              .foregroundStyle(theme.color(.accent))
            Spacer()
            Image(systemName: expanded ? "chevron.up" : "chevron.right").appSymbol(.disclosure)
              .foregroundStyle(theme.color(.icon))
          }
          .appFont(.secondary, weight: .medium)
          .padding(.top, 10).padding(.bottom, 2)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

private struct SubagentRow: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  let store: ContextColumnStore
  let subagent: ContextColumn.Subagent
  let open: () -> Void

  private var color: ThemeRole {
    switch subagent.status {
    case .running, .starting: .success
    case .permission, .question: .accent
    case .failed: .error
    case .interrupted: .warning
    case .completed, .ended: .textWeak
    }
  }
  private var finished: Bool { !subagent.status.live }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      monogram
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 8) {
          Text(subagent.work.title).appFont(.body, weight: .semibold).foregroundStyle(theme.color(.textStrong))
            .lineLimit(1)
          Circle().fill(theme.color(color)).frame(width: 8, height: 8)
          Text(subagent.status.label).appFont(.secondary).foregroundStyle(theme.color(finished ? .textSecondary : color))
            .fixedSize()
          Spacer(minLength: 4)
          Text(elapsed).appFont(.secondary).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).fixedSize()
          Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.icon))
            .opacity(subagent.work.sessionID == nil ? 0 : 1)
        }
        HStack(spacing: 10) {
          agentChip
          usage
          cache
          Spacer(minLength: 4)
          Text(ContextUsage.money(subagent.cost)).appFont(.secondary).monospacedDigit()
            .foregroundStyle(theme.color(.text)).fixedSize()
        }
        if subagent.status.live {
          FlowLine(spacing: 8) {
            HStack(spacing: 6) {
              Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.textWeak))
              Text("agora: " + now(subagent)).lineLimit(1).truncationMode(.tail)
            }
            .appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
            ForEach(subagent.resources) { resource in
              ResourceChip(resource: resource)
            }
          }
        }
        if let permission = subagent.permission {
          HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button("Permitir") { Task { await store.reply(permission, allow: true) } }
              .foregroundStyle(theme.color(.accent))
              .padding(.horizontal, 14).padding(.vertical, 4)
              .background(theme.color(.accent).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
              .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.accent), lineWidth: 1) }
            Button("Negar") { Task { await store.reply(permission, allow: false) } }
              .foregroundStyle(theme.color(.text))
              .padding(.horizontal, 14).padding(.vertical, 4)
              .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.controlBorder), lineWidth: 1) }
          }
          .appFont(.secondary, weight: .medium)
          .lineLimit(1)
          .buttonStyle(.plain)
          .disabled(store.acting.contains(permission.id))
        }
      }
    }
    .padding(.vertical, 10)
    .opacity(finished ? 0.62 : 1)
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .contextMenu {
      if subagent.work.sessionID != nil { Button("Abrir subagente", systemImage: "bubble.left", action: open) }
      if subagent.work.running {
        Button("Parar", systemImage: "stop.fill", role: .destructive) { Task { await store.stop(subagent.work) } }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(subagent.work.title), \(subagent.status.label)")
  }

  private func now(_ subagent: ContextColumn.Subagent) -> String {
    if let permission = subagent.permission { return permission.preview }
    if subagent.status == .question { return "aguardando sua resposta" }
    return subagent.work.sessionID.flatMap { store.activities[$0] } ?? "pensando"
  }

  private var elapsed: String {
    let millis = now.timeIntervalSince1970 * 1000
    if subagent.status.live { return SessionList.relativeTime(subagent.work.started, now: now).label }
    return subagent.work.duration.map { SessionList.relativeTime(millis - $0, now: now).label } ?? "—"
  }

  private var monogram: some View {
    ZStack {
      Circle().fill(theme.color(.surfaceRaised))
      Text(SessionList.monogram(subagent.work.title)).appFont(.heading, weight: .medium)
        .foregroundStyle(theme.color(.textStrong))
      Circle().trim(from: 0, to: subagent.status.live ? 0.72 : 1)
        .stroke(theme.color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .rotationEffect(.degrees(subagent.status.live ? 120 : -90))
        .padding(-3)
    }
    .frame(width: 40, height: 40)
    .padding(3)
    .accessibilityHidden(true)
  }

  private var agentChip: some View {
    let agent = store.agent(subagent.work.agent)
    return HStack(spacing: 5) {
      AgentPixels(color: subagent.work.agent.map { theme.agentColor(agent, id: $0) } ?? theme.color(.textSecondary),
        size: 12, running: false)
      Text(agent?.name.lowercased() ?? subagent.work.agent ?? "subagente")
    }
    .appFont(.caption).foregroundStyle(theme.color(.text)).lineLimit(1)
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(theme.color(.surfaceRaised), in: RoundedRectangle(cornerRadius: 7))
    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.color(.border), lineWidth: 1) }
  }

  @ViewBuilder private var usage: some View {
    if let usage = subagent.usage {
      HStack(spacing: 5) {
        ContextUsageRing(usage: usage, size: 14)
        Text(usage.totalLabel + (usage.fraction.map { " · " + ContextColumn.percent($0) } ?? "")).lineLimit(1)
      }
      .appFont(.caption).monospacedDigit().foregroundStyle(theme.color(.text))
      .accessibilityLabel(usage.contextAccessibilityLabel)
    } else {
      Text("— contexto").appFont(.caption).foregroundStyle(theme.color(.textSecondary)).fixedSize()
    }
  }

  private var cache: some View {
    let warning = (subagent.cacheHit ?? 1) < ContextColumn.cacheWarning
    return HStack(spacing: 4) {
      Image(systemName: warning ? "exclamationmark.triangle.fill" : "bolt.fill")
      Text(subagent.cacheHit.map(ContextColumn.percent) ?? "—")
    }
    .appFont(.caption).monospacedDigit()
    .foregroundStyle(theme.color(subagent.cacheHit == nil ? .textSecondary : warning ? .warning : .primary))
    .fixedSize()
    .accessibilityLabel("cache " + (subagent.cacheHit.map(ContextColumn.percent) ?? "indisponível"))
  }
}

/// The orange chip of a resource a subagent is using right now.
struct ResourceChip: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openWindow) private var openWindow
  let resource: SessionResource
  var body: some View {
    Button { openWindow(id: "resource", value: resource.id) } label: {
      HStack(spacing: 5) {
        Image(systemName: resourceSymbol(resource.kind))
        Text(ContextColumn.chip(resource)).lineLimit(1)
      }
      .appFont(.caption, weight: .medium)
      .foregroundStyle(theme.color(.primary))
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background(theme.color(.primary).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
      .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.color(.primary).opacity(0.7), lineWidth: 1) }
    }
    .buttonStyle(.plain)
    .help("Abrir \(ContextColumn.title(resource))")
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

/// Lays children out in a row and wraps them onto the next line when they do not fit.
struct FlowLine: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(proposal.width ?? .infinity, subviews)
    return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(bounds.width, subviews) {
      var x = bounds.minX
      for index in row.items {
        let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
        subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
          proposal: .init(width: min(size.width, bounds.width), height: size.height))
        x += min(size.width, bounds.width) + spacing
      }
      y += row.height + spacing
    }
  }
  private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
    var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.init(width: width, height: nil))
      let item = min(size.width, width)
      if let last = rows.last, last.width + spacing + item <= width {
        rows[rows.count - 1] = (last.items + [index], last.width + spacing + item, max(last.height, size.height))
      } else {
        rows.append(([index], item, size.height))
      }
    }
    return rows
  }
}

// MARK: - Background tasks

private struct TasksCard: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  let store: ContextColumnStore

  var body: some View {
    ContextCard {
      ContextSectionTitle(icon: "gearshape.fill", title: "Tarefas em segundo plano", count: store.tasks.count)
        .padding(.bottom, 8)
      VStack(spacing: 0) {
        ForEach(Array(store.tasks.enumerated()), id: \.element.id) { index, task in
          if index > 0 { Divider().overlay(theme.color(.border)) }
          row(task)
        }
      }
      .padding(.horizontal, 8)
      .background(theme.color(.background).opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
      .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 1) }
    }
  }

  private func row(_ task: SessionWork) -> some View {
    HStack(spacing: 12) {
      Circle().fill(theme.color(task.running ? .success : task.state == .failed ? .error : .textWeak))
        .frame(width: 9, height: 9)
      let label = ContextColumn.task(task.title)
      HStack(spacing: 0) {
        Text(label.command).lineLimit(1).truncationMode(.middle)
        if let port = label.port {
          Text(verbatim: " · :" + String(port)).foregroundStyle(theme.color(.textSecondary)).fixedSize()
        }
      }
      .appFont(.secondary).foregroundStyle(theme.color(task.running ? .textStrong : .textSecondary))
      Spacer(minLength: 6)
      Text(task.running
        ? SessionList.relativeTime(task.started, now: now).label
        : task.state.label)
        .appFont(.caption).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).fixedSize()
      Menu {
        if task.running {
          Button("Parar", systemImage: "stop.fill", role: .destructive) { Task { await store.stop(task) } }
        }
        Button("Copiar comando", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(task.title, forType: .string)
        }
      } label: {
        Image(systemName: "ellipsis").appSymbol(.inline, weight: .bold).foregroundStyle(theme.color(.text))
          .frame(width: 24, height: 20)
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
      .accessibilityLabel("Ações de \(task.title)")
    }
    .padding(.vertical, 9)
    .opacity(store.acting.contains(task.id) ? 0.5 : 1)
  }
}

// MARK: - Live resources

private struct ResourcesCard: View {
  @Environment(\.appTheme) private var theme
  let store: ContextColumnStore

  var body: some View {
    let split = ContextColumn.resources(store.resources)
    ContextCard {
      ContextSectionTitle(icon: "display", title: "Recursos ao vivo", count: store.resources.count)
        .padding(.bottom, 8)
      if !split.inUse.isEmpty {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
          alignment: .leading, spacing: 12) {
          ForEach(split.inUse) { resource in
            ResourceTile(store: store, resource: resource)
          }
        }
      }
      if !split.others.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(split.others.enumerated()), id: \.element.id) { index, resource in
            if index > 0 { Divider().overlay(theme.color(.border)) }
            ResourceLine(store: store, resource: resource)
          }
        }
        .padding(.horizontal, 6)
        .background(theme.color(.background).opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 1) }
        .padding(.top, split.inUse.isEmpty ? 0 : 12)
      }
    }
  }
}

/// A resource in use: the live picture, large, with an orange ring and who is using it.
private struct ResourceTile: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openWindow) private var openWindow
  let store: ContextColumnStore
  let resource: SessionResource

  var body: some View {
    Button { openWindow(id: "resource", value: resource.id) } label: {
      VStack(alignment: .leading, spacing: 6) {
        RoundedRectangle(cornerRadius: 12).fill(theme.color(.surfaceRaised))
          .frame(height: 118)
          .overlay {
            if let image = store.thumbnails.images[resource.id] {
              Image(resource: image).resizable().aspectRatio(contentMode: .fill)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
              Image(systemName: resourceSymbol(resource.kind)).appSymbol(.header)
                .foregroundStyle(theme.color(.textWeak))
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color(.primary), lineWidth: 1.5) }
          .overlay(alignment: .topTrailing) {
            HStack(spacing: 5) {
              Circle().fill(theme.color(.success)).frame(width: 7, height: 7)
              Text("ao vivo")
            }
            .appFont(.caption, weight: .medium).foregroundStyle(theme.color(.textStrong))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .adaptiveGlass(Capsule())
            .padding(7)
          }
        Text(ContextColumn.title(resource)).appFont(.secondary).foregroundStyle(theme.color(.textStrong)).lineLimit(1)
        HStack(spacing: 6) {
          Circle().fill(theme.color(.primary)).frame(width: 8, height: 8)
          Text(user).lineLimit(1)
        }
        .appFont(.secondary).foregroundStyle(theme.color(.primary))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(ContextColumn.title(resource)), \(user)")
  }

  private var user: String {
    if resource.state == .user { return "Você no controle" }
    let id = ContextColumn.user(of: resource, rootID: store.id, members: store.members)
    return "Agente usando · " + (id.flatMap(store.title) ?? (resource.owner?.sessionID == store.id ? "esta sessão" : "—"))
  }
}

/// A free or stopped resource: a small picture, its name, state and the age of the last frame.
private struct ResourceLine: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openWindow) private var openWindow
  @Environment(\.sessionRowDate) private var now
  let store: ContextColumnStore
  let resource: SessionResource

  var body: some View {
    Button { openWindow(id: "resource", value: resource.id) } label: {
      HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 6).fill(theme.color(.surfaceRaised))
          .frame(width: 64, height: 32)
          .overlay {
            if let image = store.thumbnails.images[resource.id] {
              Image(resource: image).resizable().aspectRatio(contentMode: .fill)
            } else {
              Image(systemName: resourceSymbol(resource.kind)).foregroundStyle(theme.color(.textWeak))
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color(.border), lineWidth: 1) }
          .opacity(resource.state.running ? 1 : 0.6)
        Text(ContextColumn.title(resource)).appFont(.secondary).foregroundStyle(theme.color(.textStrong))
          .lineLimit(1).layoutPriority(1)
        HStack(spacing: 6) {
          Circle().fill(theme.color(resource.state == .live ? .success : .textWeak)).frame(width: 8, height: 8)
          Text(resource.state.label)
        }
        .appFont(.secondary).foregroundStyle(theme.color(.textSecondary)).fixedSize()
        Spacer(minLength: 6)
        if !resource.state.running, let frame = store.thumbnails.frames[resource.id] ?? (resource.updatedAt > 0 ? resource.updatedAt : nil) {
          ViewThatFits(in: .horizontal) {
            Text("último quadro " + ContextColumn.ago(frame, now: now))
            Text(ContextColumn.ago(frame, now: now))
          }
          .appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        }
        Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.icon))
      }
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
