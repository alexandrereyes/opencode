import OpenCodeKit
import SwiftUI

/// The rows of the Sessões column, grouped by `SessionSections`, inside a `List` owned by the host.
/// The host decorates each row with its platform actions (on iOS, swipe and the long-press menu).
struct SessionColumnSections<Decorated: View>: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  @AppStorage("OpenCodeSessionSections") private var collapse = SessionSectionCollapse()
  let store: SessionStore
  let open: (SessionRow) -> Void
  let archived: () -> Void
  /// The selected IDs while the selection mode is on; tapping a row then calls `toggle` instead of `open`.
  var selection: SessionSelection = SessionSelection()
  var toggle: (SessionRow) -> Void = { _ in }
  @ViewBuilder let decorate: (SessionRow, SessionColumnRow) -> Decorated

  var body: some View {
    let sections = SessionSections.group(store.filtered, chats: store.chatsSelected, now: now)
    ForEach(sections) { section in
      let collapsed = collapse.collapsed(section.kind)
      SessionSectionHeader(section: section, collapsed: collapsed) {
        withAnimation(.snappy(duration: 0.25)) { collapse.toggle(section.kind) }
      }
      .listRowInsets(EdgeInsets(top: 12, leading: AppLayout.margin, bottom: 4, trailing: AppLayout.margin))
      .listRowSeparator(.hidden)
      .listRowBackground(theme.color(.background))
      if !collapsed {
        ForEach(section.rows) { row in
          let attention = section.kind == .attention
          let compact = section.kind != .attention && section.kind != .running
          decorate(
            row,
            SessionColumnRow(
              store: store, row: row, kind: section.kind,
              selected: selection.active ? selection.contains(row.id) : nil,
              open: selection.active ? toggle : open))
            .listRowInsets(
              attention
                ? EdgeInsets(top: 12, leading: AppLayout.margin + 6, bottom: 12, trailing: AppLayout.margin + 6)
                : EdgeInsets(
                  top: compact ? 9 : 12, leading: AppLayout.margin, bottom: compact ? 9 : 12,
                  trailing: AppLayout.margin))
            .listRowSeparator(
              attention || row.id == section.rows.last?.id ? .hidden : .visible, edges: attention ? .all : .bottom)
            .listRowSeparatorTint(theme.color(.border))
            .listRowBackground(background(attention ? row.state.tint : nil))
            .alignmentGuide(.listRowSeparatorLeading) { _ in
              compact ? AppLayout.compactRowTextInset : AppLayout.rowTextInset
            }
            // Compact rows show no preview, so only the three-line rows read transcripts.
            .onAppear { if !compact { store.show(row.session) } }
            .onDisappear { store.hide(row.session) }
        }
      }
    }
    if sections.isEmpty {
      if store.entries.isEmpty && store.loading {
        HStack {
          Spacer()
          ProgressView("Carregando sessões…")
          Spacer()
        }
        .padding(.vertical, 30).listRowSeparator(.hidden).listRowBackground(theme.color(.background))
      } else if !store.loading {
        ContentUnavailableView(
          "Nenhuma sessão", systemImage: "bubble.left.and.bubble.right",
          description: Text("As sessões aparecerão aqui quando estiverem disponíveis.")
        )
        .foregroundStyle(theme.color(.textSecondary))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.color(.background))
      }
    }
    Button(action: archived) {
      HStack(spacing: 8) {
        Image(systemName: "archivebox").appSymbol(.inline)
        Text("Arquivadas")
        Text("\(store.archived.count)").monospacedDigit()
        Spacer(minLength: 0)
      }
      .appFont(.secondary)
      .foregroundStyle(theme.color(.textSecondary))
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Arquivadas, \(store.archived.count)")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sessions-archived")
    .listRowInsets(EdgeInsets(top: 16, leading: AppLayout.margin, bottom: 16, trailing: AppLayout.margin))
    .listRowSeparator(.hidden)
    .listRowBackground(theme.color(.background))
  }

  private func background(_ tint: ThemeRole?) -> some View {
    ZStack {
      theme.color(.background)
      if let tint {
        RoundedRectangle(cornerRadius: 14).fill(theme.color(tint).opacity(theme.dark ? 0.14 : 0.10))
          .padding(.horizontal, AppLayout.margin - 6).padding(.vertical, 3)
      }
    }
  }
}

/// One row of the column, drawn by its section: three lines for "Precisa de você" and "Trabalhando",
/// compact elsewhere. Tapping opens the session; permissions keep their compact Negar and Permitir.
/// In the selection mode a leading circle marks the row and tapping toggles it (Negar/Permitir hide).
struct SessionColumnRow: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.sessionRowDate) private var now
  let store: SessionStore
  let row: SessionRow
  let kind: SessionSection.Kind
  /// Whether the row is selected, or nil outside the selection mode.
  var selected: Bool?
  let open: (SessionRow) -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: 12) {
      Button { open(row) } label: {
        HStack(spacing: 12) {
          if let selected {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .appSymbol(.header)
              .foregroundStyle(theme.color(selected ? .primary : .textWeak))
              .accessibilityHidden(true)
          }
          content
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(selected == true ? "selecionada" : "")
      .accessibilityAddTraits(selected == true ? .isSelected : [])
      .accessibilityHint(selected == nil ? "" : "Toque para marcar ou desmarcar")
      .accessibilityIdentifier("session-row-" + row.id)
      if kind == .attention && row.state == .permission && selected == nil {
        HStack(spacing: 8) {
          Button("Negar") { Task { await store.reply(row, allow: false) } }
            .foregroundStyle(theme.color(.text))
            .padding(.horizontal, 16).frame(minHeight: 34)
            .contentShape(Capsule())
            .overlay { Capsule().strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale) }
          Button("Permitir") { Task { await store.reply(row, allow: true) } }
            .padding(.horizontal, 16).frame(minHeight: 34)
            .background(theme.color(.filledButton), in: Capsule())
            .foregroundStyle(theme.color(.onFilledButton))
        }
        .appFont(.secondary, weight: .medium)
        .buttonStyle(.plain)
        .disabled(store.busy.contains(row.id) || store.permission(row) == nil)
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch kind {
    case .attention:
      SessionRowView(
        row: row, preview: preview, directory: store.directoryLabel(row.session),
        detail: SessionSections.detail(
          row, permission: store.permission(row)?.preview, question: store.question(row),
          failure: store.previews[row.id]?.failure, now: now))
    case .running:
      SessionRowView(row: row, preview: preview, directory: store.directoryLabel(row.session))
    default:
      SessionCompactRowView(row: row, directory: store.directoryLabel(row.session))
    }
  }

  private var preview: SessionPreview { store.previews[row.id] ?? SessionPreview() }
}

private struct SessionSectionHeader: View {
  @Environment(\.appTheme) private var theme
  let section: SessionSection
  let collapsed: Bool
  let toggle: () -> Void

  var body: some View {
    let title = section.title
    Button(action: toggle) {
      HStack(spacing: 8) {
        if section.kind == .pinned {
          Image(systemName: "pin.fill").appSymbol(.inline).foregroundStyle(theme.color(.icon))
        } else {
          Circle().fill(theme.color(dot)).frame(width: 8, height: 8)
        }
        Text(title).appFont(.preview, weight: .semibold).foregroundStyle(theme.color(.textStrong))
        Text("\(section.rows.count)").appFont(.footnote, weight: .medium).monospacedDigit()
          .foregroundStyle(theme.color(.text))
          .padding(.horizontal, 6).padding(.vertical, 1)
          .background(theme.color(.highlight), in: Capsule())
        Spacer(minLength: 0)
        Image(systemName: collapsed ? "chevron.down" : "chevron.up").appSymbol(.disclosure, weight: .semibold)
          .foregroundStyle(theme.color(.icon))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title), \(section.rows.count)")
    .accessibilityValue(collapsed ? "recolhida" : "expandida")
    .accessibilityHint(collapsed ? "Toque para mostrar as sessões" : "Toque para recolher as sessões")
    .accessibilityAddTraits([.isHeader, .isButton])
    .accessibilityIdentifier("session-section-" + section.id)
  }

  private var dot: ThemeRole {
    switch section.kind {
    case .attention: .primary
    case .running: .success
    default: .textWeak
    }
  }
}
