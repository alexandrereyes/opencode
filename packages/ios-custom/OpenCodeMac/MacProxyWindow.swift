import OpenCodeKit
import SwiftUI

/// The LLM proxy window (⌘⇧L, menu Janela, or a quota ring in Sessões): the iPhone's "LLM proxy" sheet laid
/// out like System Settings, with Codex, Claude and Redefinições in a sidebar and the accounts in a table.
struct MacProxyWindow: View {
  static let id = "llm-proxy"
  @Environment(\.appTheme) private var theme
  @Bindable var runtime: MacRuntime

  var body: some View {
    Group {
      if let store = runtime.store, runtime.appliedRevision == runtime.servers.revision {
        MacProxyContent(store: store.quota, runtime: runtime).id(runtime.identity)
      } else {
        ProgressView("Conectando…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(theme.color(.background))
    .task(id: runtime.servers.revision) { await runtime.prepare() }
    #if DEBUG
    .task { await MacCapture.proxy(runtime: runtime, theme: theme) }
    #endif
  }
}

private struct MacProxyContent: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: SubscriptionStore
  @Bindable var runtime: MacRuntime
  @State private var query = MacProxyLaunch.search ?? ""

  var body: some View {
    NavigationSplitView {
      List { MacProxySidebar(store: store, runtime: runtime) }
        .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    } detail: {
      Group {
        switch store.pane(runtime.proxyPane ?? .provider(.codex)) {
        case .provider(let provider):
          MacProxyProvider(store: store, runtime: runtime, provider: provider, query: query).id(provider)
        case .resets:
          MacProxyResets(store: store)
        }
      }
      .frame(minWidth: 600, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
      .background(theme.color(.background))
    }
    .navigationTitle("LLM proxy")
    .searchable(text: $query, placement: .toolbar, prompt: "Buscar conta")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { Task { await store.refresh() } } label: {
          if store.loading { ProgressView().controlSize(.small) } else { Label("Atualizar", systemImage: "arrow.clockwise") }
        }
        .disabled(store.loading).help("Atualizar LLM proxy").accessibilityIdentifier("proxy-refresh")
      }
    }
    .proxyActions(store)
    .task { await store.refresh(ifDue: true) }
  }
}

/// Codex and Claude, then Redefinições. Buttons rather than List selection: the native highlight ignores the
/// theme and uses the system accent.
struct MacProxySidebar: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  let runtime: MacRuntime

  var body: some View {
    Section {
      ForEach(store.sidebar.filter { $0.pane != .resets }) { row in
        sidebarItem(row.pane) { MacProxySidebarRow(row: row, loading: store.snapshot == nil) }
      }
    }
    Section {
      sidebarItem(.resets) {
        HStack(spacing: 10) {
          Image(systemName: "gearshape").foregroundStyle(theme.color(.icon))
            .frame(width: 30, height: 30).background(theme.color(.surface), in: Circle())
          Text("Redefinições").fontWeight(.medium)
        }
        .padding(.vertical, 3)
      }
      .accessibilityIdentifier("proxy-sidebar-resets")
    }
  }

  private func sidebarItem(_ pane: SubscriptionPane, @ViewBuilder label: () -> some View) -> some View {
    let selected = store.pane(runtime.proxyPane ?? .provider(.codex)) == pane
    return Button { runtime.proxyPane = pane } label: {
      label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(theme.color(.textStrong))
    .background {
      RoundedRectangle(cornerRadius: 10).fill(theme.color(.primary).opacity(selected ? 0.22 : 0)).padding(-5)
    }
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct MacProxySidebarRow: View {
  @Environment(\.appTheme) private var theme
  let row: SubscriptionSidebarRow
  let loading: Bool
  var body: some View {
    HStack(spacing: 10) {
      if case .provider(let provider) = row.pane {
        ProxyProviderIcon(provider: provider).frame(width: 18, height: 18)
          .frame(width: 30, height: 30).background(theme.color(.surface), in: Circle())
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(row.title).fontWeight(.medium)
        Text(loading ? "Consultando…" : SubscriptionFormat.percent(row.remaining)).font(.caption).monospacedDigit()
          .foregroundStyle(theme.color(.textSecondary))
      }
      Spacer(minLength: 4)
      QuotaRing(remaining: row.remaining, ready: row.ready, lineWidth: 3).frame(width: 20, height: 20)
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("proxy-sidebar-" + row.title.lowercased())
  }
}

/// A provider: the wide pool card, one table per plan with the selected account below it, and the footer.
private struct MacProxyProvider: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  let runtime: MacRuntime
  let provider: SubscriptionProvider
  let query: String
  @State private var focus = MacProxyLaunch.account
  @State private var sortOrder = [KeyPathComparator(\SubscriptionAccountRow.order)]

  var body: some View {
    let accounts = SubscriptionProjection.sorted(store.snapshot?.pool(provider).accounts ?? [], now: store.now)
    if store.snapshot?.pool(provider).status == "ok", !accounts.isEmpty {
      let groups = SubscriptionGroup.groups(accounts, provider: provider, now: store.now, query: query)
      let focused = SubscriptionGroup.focus(focus, summary: store.selectedIDs[provider], in: groups)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ProxyPoolHeader(store: store, provider: provider, accounts: accounts, wide: true)
          if groups.isEmpty {
            ContentUnavailableView.search(text: query).frame(minHeight: 200)
          }
          ForEach(groups) { group in
            if group.opensOthers {
              Text("Outros planos · fora do saldo acima").font(.headline)
                .foregroundStyle(theme.color(.textSecondary)).padding(.top, 6)
            }
            HStack {
              Text(Subscriptions.planLabel(group.plan).uppercased()).font(.subheadline.weight(.semibold))
              Spacer()
              Text("\(group.projection.ready)/\(group.count) disponíveis").font(.subheadline)
            }
            .foregroundStyle(theme.color(.textSecondary)).padding(.horizontal, 4)
            MacProxyTable(store: store, provider: provider, rows: group.rows.sorted(using: sortOrder),
              selection: Binding(get: { group.rows.contains { $0.id == focused } ? focused : nil },
                                 set: { if let id = $0 { focus = id } }),
              sortOrder: $sortOrder)
            if let row = group.rows.first(where: { $0.id == focused }) {
              ProxyAccountCard(store: store, provider: provider, account: row.account, wide: true) {
                store.toggleSelection(row.account, provider: provider)
              }
              .accessibilityIdentifier("proxy-account-panel")
            }
          }
          footer
        }
        .padding(20)
        .frame(maxWidth: 1180)
        .frame(maxWidth: .infinity)
      }
    } else {
      ScrollView { ProxyPoolState(store: store, provider: provider).padding(20) }
    }
  }

  private var footer: some View {
    HStack(spacing: 16) {
      Button { runtime.proxyPane = .resets } label: { Label("Redefinições", systemImage: "gearshape") }
        .buttonStyle(.plain).foregroundStyle(theme.color(.textStrong))
      Divider().frame(height: 22)
      ProxyAutomationToggle(store: store, provider: provider).toggleStyle(.switch).fixedSize()
      Spacer(minLength: 12)
      VStack(alignment: .trailing, spacing: 3) {
        Label("A seleção altera só o resumo, não a conta usada pelo modelo.", systemImage: "info.circle")
        Text(store.projection(provider).freshness(now: store.now)).foregroundStyle(theme.color(.textWeak))
          .accessibilityIdentifier("proxy-updated")
      }
      .font(.caption).foregroundStyle(theme.color(.textSecondary)).multilineTextAlignment(.trailing)
    }
    .proxyCard(theme)
  }
}

/// One plan's accounts in a native table, in the iPhone's order until a column header sorts it.
private struct MacProxyTable: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  let rows: [SubscriptionAccountRow]
  @Binding var selection: String?
  @Binding var sortOrder: [KeyPathComparator<SubscriptionAccountRow>]
  private let rowHeight = 44.0

  var body: some View {
    Table(rows, selection: $selection, sortOrder: $sortOrder) {
      TableColumn("") { row in
        let shown = store.selectedIDs[provider] == row.id
        Button { store.toggleSelection(row.account, provider: provider) } label: {
          Image(systemName: shown ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(theme.color(shown ? .primary : .textSecondary))
        }
        .buttonStyle(.plain).help("Mostrar no resumo")
        .accessibilityLabel("Mostrar \(row.name) no resumo").accessibilityAddTraits(shown ? .isSelected : [])
      }
      .width(18)
      TableColumn("Conta", value: \.name) { row in Text(row.name).foregroundStyle(theme.color(.textStrong)) }
        .width(min: 90, ideal: 130)
      TableColumn("Plano", value: \.plan) { row in Text(row.plan).foregroundStyle(theme.color(.textSecondary)) }
        .width(min: 50, ideal: 58)
      TableColumn("5 horas", value: \.fiveHourKey) { row in MacProxyMeter(value: row.fiveHour, name: "5 horas de " + row.name) }
        .width(min: 80, ideal: 100)
      TableColumn("Semana", value: \.weeklyKey) { row in
        MacProxyMeter(value: row.weekly, name: "Semana de " + row.name, pace: row.account.pace(at: store.now))
      }
      .width(min: 80, ideal: 100)
      TableColumn("Renova", value: \.renewalKey) { row in
        Text(row.renewalLabel).font(.callout).monospacedDigit()
          .foregroundStyle(theme.color(.textSecondary)).lineLimit(2)
      }
      .width(min: 66, ideal: 74)
      TableColumn("Status", value: \.statusKey) { row in
        HStack(spacing: 6) {
          Circle().frame(width: 7, height: 7)
          Text(row.state.title).lineLimit(2)
        }
        .foregroundStyle(theme.color(proxyRole(row.state.tone)))
      }
      .width(min: 90, ideal: 124)
      TableColumn("Redefinições", value: \.resetsKey) { row in
        Text(row.resets.map { SubscriptionFormat.number($0, decimals: 0) } ?? "—").monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .center)
      }
      .width(min: 56, ideal: 84)
      TableColumn("") { row in action(row) }.width(min: 76, ideal: 86)
    }
    .tableStyle(.inset(alternatesRowBackgrounds: false))
    .scrollContentBackground(.hidden)
    .scrollDisabled(true)
    .environment(\.defaultMinListRowHeight, rowHeight)
    .frame(height: 30 + rowHeight * Double(rows.count))
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 14))
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.color(.border), lineWidth: 0.75) }
  }

  @ViewBuilder private func action(_ row: SubscriptionAccountRow) -> some View {
    if row.canReset {
      let resetting = store.resetting.contains(provider.rawValue + ":" + row.id)
      Button { store.requestReset(provider, account: row.account) } label: {
        Text(resetting ? "Aplicando…" : "Usar")
      }
      .buttonStyle(.bordered).controlSize(.small).tint(theme.color(.primary))
      .disabled(resetting).help(resetting ? "Aplicando…" : "Usar redefinição")
      .accessibilityLabel(resetting ? "Aplicando…" : "Usar redefinição de " + row.name)
      .accessibilityIdentifier("proxy-reset-" + row.id)
    }
  }
}

/// A thin bar and its percent in the iPhone's tone colors; `—` when the measurement is unknown.
private struct MacProxyMeter: View {
  @Environment(\.appTheme) private var theme
  let value: Double?
  let name: String
  var pace: Double? = nil
  var body: some View {
    if let value {
      HStack(spacing: 8) {
        ProxyQuotaBar(value: value, label: name, pace: pace).frame(height: 7)
        Text(SubscriptionFormat.percent(value)).monospacedDigit().frame(minWidth: 34, alignment: .trailing)
          .foregroundStyle(theme.color(proxyRole(SubscriptionFormat.tone(value))))
      }
    } else {
      Text("—").foregroundStyle(theme.color(.textWeak)).accessibilityLabel(name + " desconhecido")
    }
  }
}

/// Redefinições: each provider's inventory and its automatic-reset switch, as in the iPhone sheet.
private struct MacProxyResets: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if store.snapshot == nil {
          ProxyPoolState(store: store, provider: .codex)
        } else {
          ForEach(store.providers) { provider in
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 10) {
                ProxyProviderIcon(provider: provider).frame(width: 22, height: 22)
                Text(provider.title).font(.title3.bold()).foregroundStyle(theme.color(.textStrong))
              }
              if store.snapshot?.pool(provider).status == "ok" {
                ProxyResetsCard(store: store, provider: provider)
              } else {
                ProxyPoolState(store: store, provider: provider)
              }
            }
          }
        }
      }
      .toggleStyle(.switch)
      .padding(20)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }
}

/// DEBUG launch options for captures: the pane, the search and the focused account.
enum MacProxyLaunch {
  #if DEBUG
  static let pane: SubscriptionPane? = MacFixture.value("-OpenCodeMacProxy").map {
    $0 == "resets" ? .resets : .provider(SubscriptionProvider(rawValue: $0) ?? .codex)
  }
  static let search = MacFixture.value("-OpenCodeMacProxySearch")
  static let account = MacFixture.value("-OpenCodeMacProxyAccount")
  #else
  static let pane: SubscriptionPane? = nil
  static let search: String? = nil
  static let account: String? = nil
  #endif
}
