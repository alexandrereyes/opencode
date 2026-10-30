import OpenCodeKit
import SwiftUI

/// The rows of the Sessões column, grouped by `SessionSections`, inside a `List` owned by the host.
/// The host decorates each row with its platform actions (on iOS, swipe and the long-press menu).
struct SessionColumnSections<Decorated: View>: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.sessionRowDate) private var now
  @Binding var collapse: SessionSectionCollapse
  let store: SessionStore
  let rows: [SessionRow]
  let scope: SessionListFilter
  let presentation: SessionListPresentation
  let open: (SessionRow) -> Void
  var openingFrame: ((String, CGRect) -> Void)?
  var archived: (() -> Void)?
  var current: String?
  var identifierPrefix = "session-row-"
  /// The selected IDs while the selection mode is on; tapping a row then calls `toggle` instead of `open`.
  var selection: SessionSelection = SessionSelection()
  var toggle: (SessionRow) -> Void = { _ in }
  @ViewBuilder let decorate: (SessionRow, SessionColumnRow) -> Decorated

  var body: some View {
    let desired = SessionSections.group(rows, now: now, held: store.attentionHold)
    let all = store.rows
    let available = Set(all.map(\.id))
    let sections = presentation.order?.resolve(all) ?? desired
    // A conversation held open in "Precisa de você" no longer counts: the number matches the bell and the watch.
    let counts = Dictionary(uniqueKeysWithValues: desired.map {
      ($0.kind, $0.kind == .attention ? SessionAttention.count($0.rows) : $0.rows.count)
    })
    Group {
      ForEach(sections) { section in
        let collapsed = collapse.collapsed(section.kind)
        SessionSectionHeader(section: section, count: counts[section.kind] ?? 0, collapsed: collapsed) {
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
                current: row.id == current, identifierPrefix: identifierPrefix,
                openingFrame: openingFrame,
                open: selection.active ? toggle : open))
              .id(row.id)
              .modifier(SessionListRowProbe(id: row.id, presentation: presentation))
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
              .modifier(SessionPreviewVisibility(row: row, store: store))
          }
        }
      }
      // Only the first load shows progress: later reloads (one per server event) must not change the rows. A
      // filter, or a server, without sessions shows no placeholder, just "Arquivadas N" when there are any.
      if store.preferences == nil && store.loading {
        HStack {
          Spacer()
          ProgressView("Carregando sessões…")
          Spacer()
        }
        .padding(.vertical, 30).listRowSeparator(.hidden).listRowBackground(theme.color(.background))
      }
      if let archived {
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
    }
    // The same row model uses a shared avatar in mixed lists and its own avatar in the Chats filter.
    .environment(\.sessionRowsMixChats, !scope.chats)
    .onChange(of: SessionListOrder(desired), initial: true) { _, order in presentation.update(order, available: available) }
    .onChange(of: available) { _, available in presentation.update(SessionListOrder(desired), available: available) }
    .onChange(of: scope) { _, _ in presentation.update(SessionListOrder(desired), reset: true, available: available) }
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

/// Permissions and questions already have their descriptions. Refresh previews only while an activity, failure or
/// unread answer row is on screen, including a state transition that does not recreate the row.
private struct SessionPreviewVisibility: ViewModifier {
  let row: SessionRow
  let store: SessionStore
  @State private var visible = false
  private var needed: Bool { row.state == .running || row.state == .failed || row.state == .unread }

  func body(content: Content) -> some View {
    content.onAppear {
      visible = true
      if needed { store.show(row.session) }
    }
    .onDisappear {
      visible = false
      store.hide(row.session)
    }
    .onChange(of: needed) { _, needed in
      guard visible else { return }
      if needed { store.show(row.session) } else { store.hide(row.session) }
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
  var current = false
  var identifierPrefix = "session-row-"
  var openingFrame: ((String, CGRect) -> Void)?
  @State private var frame = CGRect.zero
  let open: (SessionRow) -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: 12) {
      Button {
        if selected == nil { openingFrame?(row.id, frame) }
        open(row)
      } label: {
        HStack(spacing: 12) {
          if let selected {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .appSymbol(.header)
              .foregroundStyle(theme.color(selected ? .primary : .textWeak))
              .accessibilityHidden(true)
          }
           content
           if current {
             Image(systemName: "checkmark").appSymbol(.inline, weight: .semibold)
               .foregroundStyle(theme.color(.primary)).accessibilityHidden(true)
           }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(selected == true ? "selecionada" : "")
      .accessibilityAddTraits(selected == true || current ? .isSelected : [])
      .accessibilityHint(selected == nil ? "" : "Toque para marcar ou desmarcar")
      .accessibilityIdentifier(identifierPrefix + row.id)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
        if openingFrame != nil { frame = $0 }
      }
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
      // A row held open keeps the line of the reason it had when opened.
      let reason = store.attentionHold.reason(row)
      SessionRowView(
        row: row, preview: preview, directory: store.directoryLabel(row.session),
        detail: SessionSections.detail(
          row, reason: reason, permission: store.permission(row)?.preview, question: store.question(row),
          failure: preview.failure, reply: preview.reply, now: now),
        detailTint: reason?.tint)
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
  let count: Int
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
        Text("\(count)").appFont(.footnote, weight: .medium).monospacedDigit()
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
    .accessibilityLabel("\(title), \(count)")
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
