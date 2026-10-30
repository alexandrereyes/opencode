import AppKit
import OpenCodeKit
import SwiftUI

/// The rail's disk level (approved option B): a vertical bar filled with the used share, colored by the free share
/// (`DiskCleanup.level`), over the free space. A click opens Espaço em disco.
struct MacDiskIndicator: View {
  @Environment(\.appTheme) private var theme
  let disk: MacDiskStore
  let action: () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      Button(action: action) {
        VStack(spacing: 4) {
          let volume = disk.volume
          let used = volume.map { $0.total > 0 ? 1 - Double($0.free) / Double($0.total) : 0 } ?? 0
          ZStack(alignment: .bottom) {
            Capsule().fill(theme.color(.surfaceRaised))
            Capsule().fill(color(volume)).frame(height: max(4, 30 * used))
          }
          .frame(width: 11, height: 30)
          .overlay { Capsule().strokeBorder(theme.color(.border), lineWidth: 0.7) }
          Text(volume.map { DiskCleanup.bytes($0.free) } ?? "…")
            .font(.system(size: 9, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(theme.color(.textSecondary))
        }
        .frame(width: 52, height: 48).contentShape(Rectangle())
      }
      .help(help(now: context.date))
      .accessibilityLabel("Espaço em disco" + (disk.volume.map { ", \(DiskCleanup.bytes($0.free)) livres" } ?? ""))
      .accessibilityIdentifier("rail-disk")
    }
    .task { disk.start() }
  }

  private func color(_ volume: MacDiskStore.Volume?) -> Color {
    guard let volume else { return theme.color(.textWeak) }
    return switch DiskCleanup.level(free: volume.free, total: volume.total) {
    case .roomy: theme.color(.success)
    case .fair: theme.color(.textSecondary)
    case .low: theme.color(.warning)
    case .critical: theme.color(.error)
    }
  }

  private func help(now: Date) -> String {
    guard let volume = disk.volume else { return "Espaço em disco" }
    return "Disco: \(DiskCleanup.bytes(volume.free)) livres de \(DiskCleanup.bytes(volume.total)) · atualizado "
      + DiskCleanup.ago(volume.at, now: now)
  }
}

/// Espaço em disco (approved screen A): what fills the disk, the worktrees with their sessions and git state, the
/// agents' leftovers, and Limpar with a preview. Esc, Cancelar, × or a click outside closes it.
struct MacDiskSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var disk: MacDiskStore
  let sessions: SessionStore
  let window: CGSize
  @State private var filter = Filter.free

  enum Filter: String, CaseIterable, Identifiable {
    case free = "Sem sessão", linked = "Com sessão", all = "Todas"
    var id: String { rawValue }
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      VStack(alignment: .leading, spacing: 0) {
        header(now: context.date).padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
        HStack(alignment: .top, spacing: 14) {
          usage
          release
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 22)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            worktreeSection(now: context.date)
            leftoverSection(now: context.date)
          }
          .padding(.horizontal, 22).padding(.bottom, 12)
        }
        footer
      }
    }
    .frame(width: min(1060, max(800, window.width * 0.86)), height: min(880, max(560, window.height * 0.9)))
    .background(theme.color(.background))
    .onAppear { disk.open(sessions: sessions) }
    .sheet(item: $disk.plan) { plan in MacDiskPreview(disk: disk, sessions: sessions, plan: plan) }
    .confirmationDialog(confirmationTitle,
      isPresented: Binding(get: { disk.confirming != nil }, set: { if !$0 { disk.confirming = nil } }),
      presenting: disk.confirming?.worktree) { _ in
      Button(disk.confirming?.intent == .remove ? "Revisar remoção…" : "Marcar mesmo assim", role: .destructive) {
        disk.confirm()
      }
      Button("Cancelar", role: .cancel) { disk.confirming = nil }
    } message: { worktree in
      Text(Self.loss(worktree))
    }
  }

  private var confirmationTitle: String {
    "Marcar \(disk.confirming?.worktree.name ?? "a worktree") com trabalho pendente?"
  }

  static func loss(_ worktree: DiskCleanup.Worktree) -> String {
    var parts: [String] = []
    if let dirty = worktree.dirty, dirty > 0 {
      parts.append("Tem \(dirty) \(dirty == 1 ? "arquivo não commitado, que se perde" : "arquivos não commitados, que se perdem") ao remover.")
    }
    if let unpushed = worktree.unpushed, unpushed > 0 {
      parts.append(worktree.branch.map {
        "Tem \(unpushed) \(unpushed == 1 ? "commit não enviado" : "commits não enviados"); a branch \($0) não é apagada e continua com eles."
      } ?? "Tem \(unpushed) \(unpushed == 1 ? "commit não enviado" : "commits não enviados") sem branch: eles ficam soltos no repositório.")
    }
    if let ignored = worktree.ignored, !ignored.isEmpty {
      parts.append("Tem \(DiskCleanup.ignoredText(ignored)), ignorados pelo git e que nada recria: se perdem ao remover.")
    }
    parts.append("A confirmação vale só para este estado: se algo mudar, ela é pedida de novo.")
    return parts.joined(separator: " ")
  }

  // MARK: Top

  private func header(now: Date) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "internaldrive").font(.system(size: 22)).foregroundStyle(theme.color(.text))
      Text("Espaço em disco").font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.color(.textStrong))
      Spacer()
      Group {
        if disk.scanning {
          Text(disk.measuring.isEmpty ? "Calculando…" : "Calculando… faltam \(disk.measuring.count)")
        } else if let at = disk.scannedAt {
          Text("Atualizado " + DiskCleanup.ago(at, now: now))
        }
        Text("·")
        Button("Atualizar") { disk.rescan(sessions: sessions) }
          .buttonStyle(.plain).foregroundStyle(theme.color(.primary)).disabled(disk.scanning || disk.plan != nil)
      }
      .font(.system(size: 12)).foregroundStyle(theme.color(.textSecondary))
      Button { dismiss() } label: {
        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
          .background(theme.color(.surface), in: Circle())
          .overlay { Circle().strokeBorder(theme.color(.border), lineWidth: 0.7) }
      }
      .buttonStyle(.plain).foregroundStyle(theme.color(.text)).help("Fechar").accessibilityLabel("Fechar")
    }
  }

  private struct Segment: Identifiable {
    let title: String
    let bytes: Int64?
    let color: Color
    var id: String { title }
  }

  private var segments: [Segment] {
    let worktrees = disk.worktrees.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    let temp = disk.categories.reduce(Int64(0)) { $0 + $1.size }
    let devices = disk.extras.filter { [.simulators, .emulators].contains($0.kind) }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    let used = disk.volume.map { $0.total - $0.free } ?? 0
    return [
      Segment(title: "Worktrees", bytes: worktrees, color: theme.color(.accent)),
      Segment(title: "Builds dos agentes", bytes: temp, color: theme.color(.info)),
      Segment(title: "Simuladores e emuladores", bytes: devices, color: theme.avatar("cyan").background),
      Segment(title: "Outros", bytes: max(0, used - worktrees - temp - devices), color: theme.color(.textWeak)),
      Segment(title: "Livre", bytes: disk.volume?.free, color: theme.color(.success)),
    ]
  }

  private var usage: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let volume = disk.volume {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(DiskCleanup.bytes(volume.total)).fontWeight(.semibold).foregroundStyle(theme.color(.textStrong))
          Text("·").foregroundStyle(theme.color(.textSecondary))
          Text(DiskCleanup.bytes(volume.free)).fontWeight(.semibold).foregroundStyle(theme.color(.textStrong))
          Text("livres (\(Int((Double(volume.free) / Double(max(volume.total, 1)) * 100).rounded()))%)")
            .foregroundStyle(theme.color(.textSecondary))
        }
        .font(.system(size: 16))
      }
      let segments = segments
      let total = Double(max(disk.volume?.total ?? 1, 1))
      GeometryReader { proxy in
        HStack(spacing: 0) {
          ForEach(segments) { segment in
            Rectangle().fill(segment.color).frame(width: proxy.size.width * Double(segment.bytes ?? 0) / total)
          }
          Spacer(minLength: 0)
        }
        .background(theme.color(.surfaceRaised))
        .clipShape(Capsule())
      }
      .frame(height: 18)
      HStack(alignment: .top, spacing: 22) {
        ForEach(segments) { segment in
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(segment.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
              Text(segment.title).font(.system(size: 12)).foregroundStyle(theme.color(.text))
              Text(segment.bytes.map(DiskCleanup.bytes) ?? "…").font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(theme.color(.textSecondary))
            }
          }
          .help(segment.title == "Builds dos agentes" ? "Tudo em \(disk.roots.temp)" : "")
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 0.7) }
  }

  private var release: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Dá para liberar").font(.system(size: 13)).foregroundStyle(theme.color(.textSecondary))
      Text(DiskCleanup.bytes(disk.freeable)).font(.system(size: 30, weight: .semibold)).monospacedDigit()
        .foregroundStyle(theme.color(.primary))
      Spacer(minLength: 0)
      cleanButton(expands: true)
    }
    .padding(16)
    .frame(width: 230, alignment: .leading)
    .frame(maxHeight: .infinity)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 0.7) }
  }

  private func cleanButton(expands: Bool) -> some View {
    let amount = disk.freeable
    let enabled = (amount > 0 || !disk.selected.isEmpty) && disk.plan == nil
    return Button { disk.preview() } label: {
      Text("Limpar \(DiskCleanup.bytes(amount))…").font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.color(.onPrimary))
        .frame(maxWidth: expands ? .infinity : nil).padding(.horizontal, 16).frame(height: 32)
        .background(theme.color(.primary).opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain).disabled(!enabled)
    .accessibilityIdentifier("disk-clean")
  }

  // MARK: Worktrees

  private func count(_ filter: Filter) -> Int { disk.worktrees.filter { matches($0, filter) }.count }

  private func matches(_ worktree: DiskCleanup.Worktree, _ filter: Filter) -> Bool {
    switch filter {
    case .free: worktree.sessions.active == 0
    case .linked: worktree.sessions.active > 0
    case .all: true
    }
  }

  private func worktreeSection(now: Date) -> some View {
    let rows = disk.worktrees.filter { matches($0, filter) }
    let total = disk.worktrees.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    return VStack(alignment: .leading, spacing: 0) {
      HStack {
        sectionTitle("Worktrees · \(disk.worktrees.count) · \(DiskCleanup.bytes(total))")
        Spacer()
        HStack(spacing: 2) {
          ForEach(Filter.allCases) { option in
            Button { filter = option } label: {
              Text(option == .all || !disk.local ? option.rawValue : "\(option.rawValue)  \(count(option))")
                .font(.system(size: 12, weight: filter == option ? .semibold : .regular))
                .foregroundStyle(theme.color(filter == option ? .textStrong : .textSecondary))
                .padding(.horizontal, 14).frame(height: 26)
                .background(theme.color(.highlight).opacity(filter == option ? 1 : 0), in: Capsule())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(2)
        .background(theme.color(.surface), in: Capsule())
        .overlay { Capsule().strokeBorder(theme.color(.border), lineWidth: 0.7) }
      }
      .padding(.top, 20).padding(.bottom, 6)
      if !disk.local {
        notice("O servidor conectado não está neste Mac: as sessões dele não dizem nada sobre estas pastas. A limpeza de worktrees fica desligada; só os tamanhos aparecem.")
      }
      if rows.isEmpty {
        Text(disk.scanning && disk.worktrees.isEmpty ? "Procurando worktrees…" : "Nenhuma worktree aqui.")
          .font(.system(size: 12)).foregroundStyle(theme.color(.textSecondary)).padding(.vertical, 12)
      }
      ForEach(rows) { worktree in
        MacDiskWorktreeRow(disk: disk, worktree: worktree, project: disk.projects[worktree.path], now: now)
      }
    }
  }

  private func notice(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.color(.warning))
      Text(text).font(.system(size: 12)).foregroundStyle(theme.color(.text)).fixedSize(horizontal: false, vertical: true)
    }
    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.color(.warning).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    .padding(.vertical, 6)
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.9)
      .foregroundStyle(theme.color(.textStrong))
  }

  // MARK: Leftovers

  private func leftoverSection(now: Date) -> some View {
    let total = disk.categories.reduce(Int64(0)) { $0 + $1.size } + disk.extras.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    return VStack(alignment: .leading, spacing: 0) {
      sectionTitle("Sujeira dos agentes · \(DiskCleanup.bytes(total))").padding(.top, 22).padding(.bottom, 6)
      if disk.categories.isEmpty, disk.scanning {
        Text("Listando \(MacDiskWorktreeRow.abbreviated(disk.roots.temp))…").font(.system(size: 12))
          .foregroundStyle(theme.color(.textSecondary)).padding(.vertical, 8)
      }
      ForEach(disk.categories) { category in
        let kind = category.kind
        let automatic = DiskCleanup.automatic(kind)
        var detail = category.summary
        if automatic, category.measured, category.removable != category.size {
          detail += category.removable == 0 ? " · nada a limpar agora" : " · limpa \(DiskCleanup.bytes(category.removable))"
        }
        if !automatic { detail += " · só manual" }
        return MacDiskCategoryRow(title: Self.title(kind), symbol: Self.symbol(kind), tint: Self.tint(kind, theme),
          detail: detail, size: category.measured ? category.size : nil, partial: category.size,
          selected: automatic ? Binding(get: { disk.kinds.contains(kind) }, set: { on in
            if on { disk.kinds.insert(kind) } else { disk.kinds.remove(kind) }
          }) : nil,
          reveal: automatic ? nil : disk.roots.temp)
      }
      ForEach(disk.extras) { extra in
        var detail = extra.detail
        if let size = extra.unavailableSize, !extra.unavailable.isEmpty { detail += " · limpa \(DiskCleanup.bytes(size))" }
        return MacDiskCategoryRow(title: extra.title, symbol: Self.symbol(extra.kind), tint: Self.tint(extra.kind, theme),
          detail: detail, size: extra.size, partial: 0,
          selected: extra.kind == .simulators && !extra.unavailable.isEmpty
            ? Binding(get: { disk.simulators }, set: { disk.simulators = $0 }) : nil,
          reveal: extra.paths.first)
      }
    }
  }

  static func title(_ kind: DiskCleanup.Leftover.Kind) -> String {
    switch kind {
    case .build: "Builds temporários do Xcode"
    case .tests: "Resultados de testes"
    case .app: "Apps copiados"
    case .log: "Logs"
    case .capture: "Capturas e uploads"
    case .other: "Outros temporários"
    }
  }

  private static func symbol(_ kind: DiskCleanup.Leftover.Kind) -> String {
    switch kind {
    case .build: "hammer.fill"
    case .tests: "checkmark.seal"
    case .app: "app.dashed"
    case .log: "doc.text"
    case .capture: "photo.on.rectangle"
    case .other: "folder"
    }
  }

  private static func tint(_ kind: DiskCleanup.Leftover.Kind, _ theme: AppTheme) -> Color {
    switch kind {
    case .build: theme.color(.info)
    case .tests: theme.color(.success)
    case .app, .log, .capture, .other: theme.color(.icon)
    }
  }

  private static func symbol(_ kind: MacDiskExtra.Kind) -> String {
    switch kind {
    case .simulators: "iphone"
    case .emulators: "candybarphone"
    case .snapshots: "square.stack.3d.up"
    case .derivedData: "hammer"
    case .packages: "shippingbox"
    case .caches: "archivebox"
    }
  }

  private static func tint(_ kind: MacDiskExtra.Kind, _ theme: AppTheme) -> Color {
    switch kind {
    case .simulators: theme.color(.text)
    case .emulators: theme.color(.success)
    case .snapshots: theme.color(.accent)
    case .derivedData: theme.color(.info)
    case .packages, .caches: theme.color(.icon)
    }
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Limpar remove só o que não tem sessão vinculada nem alterações pendentes; as branches ficam.")
        Text("Worktrees com sessão ou com alterações não commitadas ficam, e nada em uso ou alterado nas últimas 24 h sai.")
      }
      .font(.system(size: 12)).foregroundStyle(theme.color(.textSecondary))
      Spacer(minLength: 12)
      Button { dismiss() } label: {
        Text("Cancelar").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.color(.text))
          .padding(.horizontal, 16).frame(height: 32)
          .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 7))
          .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.color(.border), lineWidth: 0.7) }
      }
      .buttonStyle(.plain).keyboardShortcut(.cancelAction)
      cleanButton(expands: false)
    }
    .padding(.horizontal, 22).padding(.vertical, 14)
    .overlay(alignment: .top) { Rectangle().fill(theme.color(.border)).frame(height: 0.7) }
  }
}

/// A worktree: the box, the project's avatar, name, path · branch, size, its state and, on hover, Finder and Remover.
private struct MacDiskWorktreeRow: View {
  @Environment(\.appTheme) private var theme
  let disk: MacDiskStore
  let worktree: DiskCleanup.Worktree
  let project: Project?
  let now: Date
  @State private var hovered = false

  var body: some View {
    let verdict = disk.verdict(worktree)
    let status = DiskCleanup.status(worktree, local: disk.local, now: now)
    HStack(spacing: 12) {
      MacDiskCheckbox(on: disk.selected.contains(worktree.path), enabled: verdict != .locked) { disk.toggle(worktree) }
      avatar
      VStack(alignment: .leading, spacing: 2) {
        Text(worktree.name).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.color(.textStrong))
          .lineLimit(1)
        Text(MacDiskWorktreeRow.abbreviated(worktree.path) + (worktree.branch.map { "  ·  " + $0 } ?? ""))
          .font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary)).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 8)
      HStack(spacing: 4) {
        icon("folder", help: "Mostrar no Finder") { MacDiskWorktreeRow.reveal(worktree.path) }
        icon("trash", help: verdict == .locked ? "Não dá para remover: \(status.title.lowercased())" : "Remover…") {
          disk.preview(only: worktree)
        }
        .disabled(verdict == .locked || disk.plan != nil)
      }
      .opacity(hovered ? 1 : 0)
      size.frame(width: 86, alignment: .trailing)
      state(status).frame(width: 214, alignment: .leading)
      Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary))
        .opacity(status.locked ? 1 : 0).frame(width: 14)
        .help(status.locked ? "Não pode ser marcada" : "")
    }
    .padding(.vertical, 7)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .overlay(alignment: .bottom) { Rectangle().fill(theme.color(.border)).frame(height: 0.5) }
    .contextMenu {
      Button("Mostrar no Finder", systemImage: "folder") { MacDiskWorktreeRow.reveal(worktree.path) }
      Button("Copiar caminho", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(worktree.path, forType: .string)
      }
      Divider()
      Button("Remover…", systemImage: "trash", role: .destructive) { disk.preview(only: worktree) }
        .disabled(verdict == .locked)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(worktree.name), \(status.title)" + (status.detail.map { ", \($0)" } ?? ""))
    .accessibilityIdentifier("disk-worktree-" + worktree.name)
  }

  @ViewBuilder private var avatar: some View {
    if let project {
      ProjectAvatar(project: project, size: 30, style: .caption)
    } else {
      Text(SessionList.monogram(worktree.name)).font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.color(.text)).frame(width: 30, height: 30)
        .background(theme.color(.highlight), in: Circle())
    }
  }

  @ViewBuilder private var size: some View {
    let measuring = disk.measuring.contains(worktree.path)
    if let bytes = worktree.size {
      Text(DiskCleanup.bytes(bytes)).font(.system(size: 13)).monospacedDigit()
        .foregroundStyle(theme.color(measuring ? .textWeak : .textStrong))
        .help(measuring ? "Medida anterior; calculando de novo" : "")
    } else {
      Text(measuring ? "calculando…" : "—").font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary))
    }
  }

  @ViewBuilder private func state(_ status: DiskCleanup.Status) -> some View {
    switch status.tone {
    case .warning:
      HStack(alignment: .top, spacing: 5) {
        Image(systemName: "exclamationmark.triangle.fill")
        VStack(alignment: .leading, spacing: 1) {
          Text(status.title)
          if let detail = status.detail { Text(detail) }
        }
      }
      .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.color(.warning))
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(theme.color(.warning).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    case .neutral, .working:
      let working = status.tone == .working
      HStack(spacing: 8) {
        Circle().fill(working ? theme.color(.success) : theme.color(.textWeak)).frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 1) {
          Text(status.title).font(.system(size: 11, weight: .medium))
            .foregroundStyle(working ? theme.color(.success) : theme.color(.text))
          if let detail = status.detail {
            Text(detail).font(.system(size: 11)).foregroundStyle(working ? theme.color(.success) : theme.color(.textSecondary))
          }
        }
      }
    }
  }

  private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 24)
        .foregroundStyle(theme.color(.textSecondary))
    }
    .buttonStyle(.plain).help(help).accessibilityLabel(help)
  }

  static func abbreviated(_ path: String) -> String {
    let home = NSHomeDirectory()
    return DiskCleanup.contains(home, path) ? "~" + path.dropFirst(home.count) : path
  }

  static func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
}

/// A row of Sujeira dos agentes: a box when Limpar can take it, else Finder.
private struct MacDiskCategoryRow: View {
  @Environment(\.appTheme) private var theme
  let title: String
  let symbol: String
  let tint: Color
  let detail: String
  /// nil while measuring; `partial` is what is measured so far.
  let size: Int64?
  let partial: Int64
  let selected: Binding<Bool>?
  let reveal: String?

  var body: some View {
    HStack(spacing: 12) {
      if let selected {
        MacDiskCheckbox(on: selected.wrappedValue, enabled: true) { selected.wrappedValue.toggle() }
      } else {
        Color.clear.frame(width: 16, height: 16)
      }
      Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(tint).frame(width: 30)
      Text(title).font(.system(size: 13)).foregroundStyle(theme.color(.textStrong)).lineLimit(1)
      Text(detail).font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      if let reveal {
        Button { MacDiskWorktreeRow.reveal(reveal) } label: {
          Image(systemName: "folder").font(.system(size: 12)).frame(width: 24, height: 24)
            .foregroundStyle(theme.color(.textSecondary))
        }
        .buttonStyle(.plain).help("Mostrar no Finder").accessibilityLabel("Mostrar no Finder")
      }
      Group {
        if let size {
          Text(DiskCleanup.bytes(size)).font(.system(size: 13)).foregroundStyle(theme.color(.textStrong))
        } else {
          Text(partial > 0 ? "\(DiskCleanup.bytes(partial))…" : "calculando…").font(.system(size: 11))
            .foregroundStyle(theme.color(.textSecondary))
        }
      }
      .monospacedDigit().frame(width: 86, alignment: .trailing)
    }
    .padding(.vertical, 7)
    .overlay(alignment: .bottom) { Rectangle().fill(theme.color(.border)).frame(height: 0.5) }
    .accessibilityElement(children: .combine)
  }
}

private struct MacDiskCheckbox: View {
  @Environment(\.appTheme) private var theme
  let on: Bool
  let enabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      RoundedRectangle(cornerRadius: 4)
        .fill(on ? theme.color(.primary) : Color.clear)
        .overlay {
          RoundedRectangle(cornerRadius: 4).strokeBorder(on ? theme.color(.primary) : theme.color(.borderStrong), lineWidth: 1)
        }
        .overlay {
          if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.color(.onPrimary)) }
        }
        .frame(width: 16, height: 16).opacity(enabled ? 1 : 0.35)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(!enabled)
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

/// The preview of Limpar, then its progress and results. Nothing is removed before Apagar.
struct MacDiskPreview: View {
  @Environment(\.appTheme) private var theme
  @Bindable var disk: MacDiskStore
  let sessions: SessionStore
  let plan: MacDiskPlan

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let progress = disk.progress { results(progress) } else { preview }
    }
    .padding(22)
    .frame(width: 660)
    .frame(minHeight: 200, maxHeight: 660, alignment: .topLeading)
    .background(theme.color(.background))
    .interactiveDismissDisabled(disk.progress.map { !$0.finished } ?? false)
  }

  private var risky: [DiskCleanup.Worktree] { plan.worktrees.filter(\.pending) }

  @ViewBuilder private var preview: some View {
    Text("Apagar cerca de \(DiskCleanup.bytes(plan.total)) deste Mac?").font(.system(size: 18, weight: .semibold))
      .foregroundStyle(theme.color(.textStrong))
    Text("As worktrees saem com git worktree remove e as branches ficam. Antes de cada item, as sessões (lidas de novo no servidor), os processos, o git e as mudanças recentes são conferidos; o que mudou fica.")
      .font(.system(size: 12)).foregroundStyle(theme.color(.textSecondary)).fixedSize(horizontal: false, vertical: true)
    if !risky.isEmpty {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.color(.warning))
        Text("\(risky.count == 1 ? "1 worktree tem" : "\(risky.count) worktrees têm") trabalho pendente que você confirmou: os arquivos não commitados e os ignorados listados se perdem. Se algo mudar até lá, ela fica.")
          .font(.system(size: 12)).foregroundStyle(theme.color(.text)).fixedSize(horizontal: false, vertical: true)
      }
      .padding(10).frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.color(.warning).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if !plan.worktrees.isEmpty {
          heading("Worktrees · \(plan.worktrees.count)")
          ForEach(plan.worktrees) { worktree in
            line(worktree.name, detail: MacDiskWorktreeRow.abbreviated(worktree.path)
              + (worktree.pending ? " · " + (DiskCleanup.status(worktree, local: true, now: .now).title) : ""),
              bytes: worktree.size, warning: worktree.pending)
          }
        }
        let groups = DiskCleanup.Leftover.Kind.allCases.compactMap { kind -> (DiskCleanup.Leftover.Kind, [DiskCleanup.Leftover])? in
          let items = plan.leftovers.filter { $0.kind == kind }
          return items.isEmpty ? nil : (kind, items)
        }
        if !groups.isEmpty || plan.simulators != nil {
          heading("Sujeira dos agentes")
          ForEach(groups, id: \.0) { kind, items in
            line(MacDiskSheet.title(kind), detail: "\(items.count) \(items.count == 1 ? "item" : "itens") em \(MacDiskWorktreeRow.abbreviated(disk.roots.temp))",
              bytes: items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }, warning: false)
          }
          if let simulators = plan.simulators {
            line("Simuladores indisponíveis", detail: "\(simulators.unavailable.count) aparelhos · xcrun simctl delete unavailable",
              bytes: simulators.unavailableSize, warning: false)
          }
        }
      }
    }
    .frame(maxHeight: 380)
    HStack {
      Text("Total: \(DiskCleanup.bytes(plan.total))").font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.color(.textStrong))
      Spacer()
      Button("Cancelar") { disk.cancelPreview() }.keyboardShortcut(.cancelAction)
      Button("Apagar", role: .destructive) { disk.startCleaning(plan, sessions: sessions) }
        .accessibilityIdentifier("disk-confirm")
    }
  }

  @ViewBuilder private func results(_ progress: MacDiskProgress) -> some View {
    if progress.finished {
      let kept = progress.lines.filter { !$0.removed }
      Text("Cerca de \(DiskCleanup.bytes(progress.removed)) removidos").font(.system(size: 18, weight: .semibold))
        .foregroundStyle(theme.color(.textStrong))
      if let before = progress.freeBefore, let after = progress.freeAfter {
        Text("Espaço livre: \(DiskCleanup.bytes(before)) → \(DiskCleanup.bytes(after)). Snapshots locais e espaço purgável podem atrasar a diferença.")
          .font(.system(size: 12)).foregroundStyle(theme.color(.text)).fixedSize(horizontal: false, vertical: true)
      }
      if let stopped = progress.stopped {
        Text("Parou antes do fim: \(stopped).").font(.system(size: 12, weight: .medium))
          .foregroundStyle(theme.color(.warning))
      }
      Text("\(progress.lines.count - kept.count) de \(progress.lines.count) itens removidos. Registro em \(MacDiskWorktreeRow.abbreviated(disk.roots.log.path)).")
        .font(.system(size: 12)).foregroundStyle(theme.color(.textSecondary))
      if !kept.isEmpty {
        heading("Ficaram · \(kept.count)")
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(kept) { line in
              self.line(URL(fileURLWithPath: line.path).lastPathComponent, detail: line.reason ?? "", bytes: line.bytes,
                warning: true)
            }
          }
        }
        .frame(maxHeight: 300)
      }
      HStack {
        Spacer()
        Button("Concluído") { disk.finish() }.keyboardShortcut(.cancelAction)
      }
    } else {
      Text("Limpando…").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.color(.textStrong))
      ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
      HStack {
        Text("\(progress.done) de \(progress.total)" + (progress.current.map { " · \($0)" } ?? ""))
          .font(.system(size: 12)).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        Spacer()
        // Stops before the next item; a git command waiting on something is ended.
        Button("Parar") { disk.stop() }.accessibilityIdentifier("disk-stop")
      }
    }
  }

  private func heading(_ text: String) -> some View {
    Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.9)
      .foregroundStyle(theme.color(.textSecondary)).padding(.top, 10).padding(.bottom, 4)
  }

  private func line(_ title: String, detail: String, bytes: Int64?, warning: Bool) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 13)).foregroundStyle(theme.color(.textStrong)).lineLimit(1)
        Text(detail).font(.system(size: 11)).foregroundStyle(theme.color(warning ? .warning : .textSecondary))
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer()
      Text(bytes.map(DiskCleanup.bytes) ?? "—").font(.system(size: 12)).monospacedDigit()
        .foregroundStyle(theme.color(.text))
    }
    .padding(.vertical, 5)
    .overlay(alignment: .bottom) { Rectangle().fill(theme.color(.border)).frame(height: 0.5) }
  }
}
