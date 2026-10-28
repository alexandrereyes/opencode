import OpenCodeKit
import SwiftUI

/// The conversation header's quick switcher: the rows the Sessões tab already keeps (no server reload), most
/// recent activity first, with local search. Its own view, so the conversation's streaming never re-renders it.
struct SessionSwitcherSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let sessions: SessionStore
  let current: String
  let choose: (String) -> Void
  let newSession: () -> Void
  @State private var search = ""

  var body: some View {
    #if os(iOS)
    NavigationStack {
      list
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar sessão")
        .navigationTitle("Sessões").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Fechar", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("switcher-close")
          }
        }
    }
    .sessionRowTimeline()
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    .tint(theme.color(.primary))
    #else
    // A popover under the title on the Mac: the search field on top, Return opens the first match.
    VStack(spacing: 0) {
      TextField("Buscar sessão", text: $search)
        .textFieldStyle(.roundedBorder).padding(10)
        .onSubmit {
          if let first = SessionSwitcher.rows(sessions.rows, query: search, label: { sessions.directoryLabel($0) }).first {
            choose(first.id)
          }
        }
      list
    }
    .sessionRowTimeline()
    .tint(theme.color(.primary))
    #endif
  }

  private var list: some View {
    let rows = SessionSwitcher.rows(sessions.rows, query: search) { sessions.directoryLabel($0) }
    return ScrollViewReader { proxy in
        List {
          ForEach(rows) { row in
            Button {
              choose(row.id)
            } label: {
              HStack(alignment: .top, spacing: 10) {
                SessionCompactRowView(row: row, directory: sessions.directoryLabel(row.session), showsWorking: true)
                if row.id == current {
                  Image(systemName: "checkmark").appSymbol(.inline, weight: .semibold)
                    .foregroundStyle(theme.color(.primary)).padding(.top, 24).accessibilityHidden(true)
                }
              }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(row.id == current ? .isSelected : [])
            .accessibilityIdentifier("switcher-row-" + row.id)
            .id(row.id)
            .listRowInsets(EdgeInsets(top: 9, leading: AppLayout.margin, bottom: 9, trailing: AppLayout.margin))
            .listRowSeparatorTint(theme.color(.border))
            .listRowBackground(
              row.id == current
                ? AnyView(
                  RoundedRectangle(cornerRadius: 14).fill(theme.color(.surface))
                    .padding(.horizontal, AppLayout.margin - 6).padding(.vertical, 2))
                : AnyView(theme.color(.background)))
            .alignmentGuide(.listRowSeparatorLeading) { _ in AppLayout.compactRowTextInset }
          }
          if rows.isEmpty {
            Text(search.isEmpty ? "Nenhuma sessão" : "Nenhuma sessão encontrada")
              .appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
              .listRowBackground(theme.color(.background)).listRowSeparator(.hidden)
          }
          Button(action: newSession) {
            Label("Nova sessão", systemImage: "plus").appFont(.secondary, weight: .medium)
              .foregroundStyle(theme.color(.primary)).frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 16).frame(minHeight: 48)
              .background(theme.color(.primary).opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
              .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.color(.primary).opacity(0.25)) }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("switcher-new-session")
          .listRowInsets(EdgeInsets(top: 12, leading: AppLayout.margin, bottom: 12, trailing: AppLayout.margin))
          .listRowSeparator(.hidden).listRowBackground(theme.color(.background))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden).background(theme.color(.background))
        #if os(iOS)
        .scrollEdgeEffectStyle(.hard, for: .top)
        #endif
        .onAppear { proxy.scrollTo(current, anchor: .center) }
      }
  }
}
