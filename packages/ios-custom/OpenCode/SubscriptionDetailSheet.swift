import OpenCodeKit
import SwiftUI

/// The LLM proxy details on the iPhone ("Agora primeiro", approved 1 November): Codex or Claude, what is ready now
/// with the Sessões strip's marks, the next release and the next weekly renewal, then every plan with each account's
/// state, its two windows and its credits, resets and "Destacar no resumo". Built on `SubscriptionDetails`, which
/// reuses `SubscriptionMarks`; the Mac window keeps its own design.
struct SubscriptionDetailSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var store: SubscriptionStore
  let initialProvider: SubscriptionProvider
  @State private var provider = SubscriptionProvider.codex
  private var activeProvider: SubscriptionProvider { store.providers.contains(provider) ? provider : .codex }

  var body: some View {
    let details = store.details(activeProvider)
    NavigationStack {
      VStack(spacing: 0) {
        header(details)
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if store.providers.count > 1 {
              ProxyProviderSwitch(store: store, selection: $provider)
            }
            if let details, details.groups.contains(where: { !$0.accounts.isEmpty }) {
              ProxyNowCard(details: details, now: store.now)
              ForEach(details.groups) { group in
                ProxyPlanSection(store: store, provider: activeProvider, group: group)
              }
              ProxyDetailResetsCard(store: store, provider: activeProvider, resets: details.resets)
              Label("Destacar marca a conta na faixa de Sessões, entre as outras; não muda a conta usada pelo modelo.",
                    systemImage: "info.circle")
                .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
            } else {
              ProxyPoolState(store: store, provider: activeProvider)
            }
          }
          .padding(16)
        }
        .background(theme.color(.background)).accessibilityIdentifier("proxy-detail")
        .refreshable { await store.refresh() }
      }
      .background(theme.color(.background))
      .toolbar(.hidden, for: .navigationBar)
      .proxyActions(store)
    }
    .presentationDetents([.large]).presentationDragIndicator(.visible)
    .task { provider = initialProvider; await store.refresh(ifDue: true) }
  }

  private func header(_ details: SubscriptionDetails?) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("LLM proxy").font(.largeTitle.bold()).foregroundStyle(theme.color(.textStrong))
        if let observed = details?.observedAt {
          Text(SubscriptionFormat.age(observed, now: store.now)).appFont(.secondary)
            .foregroundStyle(theme.color(.textSecondary)).accessibilityIdentifier("proxy-updated")
        }
      }
      Spacer(minLength: 0)
      Button { Task { await store.refresh() } } label: {
        if store.loading { ProgressView().frame(width: 26, height: 26) }
        else { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
      }.adaptiveGlassButtonStyle().buttonBorderShape(.circle).disabled(store.loading)
        .accessibilityLabel("Atualizar LLM proxy").accessibilityIdentifier("proxy-refresh")
      Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
        .adaptiveGlassButtonStyle(prominent: true).buttonBorderShape(.circle).tint(theme.color(.primary))
        .foregroundStyle(theme.color(.onPrimary)).accessibilityLabel("Fechar").accessibilityIdentifier("proxy-close")
    }
    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 8)
  }
}

/// Codex / Claude, each with how many accounts are ready: one tap switches, with the answer already on the button.
private struct ProxyProviderSwitch: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let store: SubscriptionStore
  @Binding var selection: SubscriptionProvider

  var body: some View {
    let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
    layout {
      ForEach(store.providers) { provider in
        let selected = provider == selection
        Button {
          guard !selected else { return }
          selection = provider
          Haptics.play(.selection)
        } label: {
          HStack(spacing: 10) {
            ProxyProviderIcon(provider: provider).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
              Text(provider.title).appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
              Text(summary(provider)).appFont(.caption).foregroundStyle(theme.color(selected ? .text : .textSecondary))
            }
          }
          .frame(maxWidth: .infinity).padding(.vertical, 8).padding(.horizontal, 8)
          .background(selected ? theme.color(.highlight) : .clear, in: RoundedRectangle(cornerRadius: 12))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.title + ", " + summary(provider))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("proxy-provider-" + provider.rawValue)
      }
    }
    .padding(4)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 16))
    .accessibilityElement(children: .contain).accessibilityIdentifier("proxy-provider")
  }

  private func summary(_ provider: SubscriptionProvider) -> String {
    guard let status = store.snapshot?.pool(provider).status else { return "consultando…" }
    guard status == "ok", let marks = store.marks(provider) else { return status == "unconfigured" ? "sem LLM proxy" : "indisponível" }
    return marks.summary(now: store.now, release: false)
  }
}

/// "Agora": how many accounts are ready, the strip's marks by plan, when the next stopped one is back and when the
/// next week renews (a renewal, not a release).
private struct ProxyNowCard: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var glyph = 15.0
  let details: SubscriptionDetails
  let now: Date

  var body: some View {
    let marks = details.marks
    VStack(alignment: .leading, spacing: 12) {
      Text("AGORA").appFont(.caption, weight: .semibold).foregroundStyle(theme.color(.textSecondary))
      Text("\(Text("\(marks.ready)").foregroundStyle(theme.color(marks.ready > 0 ? .primary : .textStrong))) de \(marks.total) \(marks.total == 1 ? "pronta" : "prontas")")
        .font(.title2.bold()).foregroundStyle(theme.color(.textStrong))
        .accessibilityIdentifier("proxy-ready")
      if marks.total > 0 {
        // Accessibility sizes list the plans one per line, with counts by state.
        let large = dynamicTypeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
          : AnyLayout(MCPFlowLayout(spacing: 16, centered: false))
        layout {
          ForEach(marks.groups) { group in
            HStack(spacing: 6) {
              Text(group.title).appFont(.secondary).foregroundStyle(theme.color(.text))
              if large || group.accounts.count > 12 {
                ForEach(SubscriptionMarks.Kind.allCases.filter { group.count($0) > 0 }, id: \.self) { kind in
                  HStack(spacing: 2) {
                    SubscriptionMarkGlyph(kind: kind, size: glyph)
                    Text("\(group.count(kind))").appFont(.secondary).foregroundStyle(theme.color(.text))
                  }
                }
              } else {
                HStack(spacing: 3) {
                  ForEach(group.accounts) { account in
                    SubscriptionMarkGlyph(kind: .init(account.mark), pinned: account.pinned, size: glyph)
                  }
                }
              }
            }
            .fixedSize(horizontal: !large, vertical: true)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(marks.spoken("Contas", now: now))
        #if DEBUG
        .accessibilityValue(Self.fixture(marks))
        #endif
        .accessibilityIdentifier("proxy-now-marks")
      }
      Rectangle().fill(theme.color(.border)).frame(height: 0.5)
      if let release = details.release {
        line("clock.fill", .warning, "Próxima liberação", cause: release.cause.map(Self.cause),
             value: Self.names(release.names) + " · " + SubscriptionFormat.moment(release.at, now: now), id: "proxy-release")
      } else if details.stoppedWithoutTime > 0 {
        line("clock.fill", .warning, "Próxima liberação", cause: nil, value: "sem horário informado", id: "proxy-release")
      }
      if let renewal = details.renewal {
        line("arrow.clockwise", .primary, "Próxima renovação semanal", cause: nil,
             value: Self.names(renewal.names) + " · " + SubscriptionFormat.moment(renewal.at, now: now), id: "proxy-renewal")
      } else {
        line("arrow.clockwise", .primary, "Próxima renovação semanal", cause: nil, value: "não informada", id: "proxy-renewal")
      }
    }
    .proxyDetailCard(theme)
    .accessibilityElement(children: .contain).accessibilityIdentifier("proxy-now")
  }

  private func line(_ symbol: String, _ role: ThemeRole, _ title: String, cause: String?, value: String, id: String) -> some View {
    let label = HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol).foregroundStyle(theme.color(role)).frame(width: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).foregroundStyle(theme.color(.text))
        if let cause { Text(cause).appFont(.caption).foregroundStyle(theme.color(.textSecondary)) }
      }
    }
    let text = Text(value).foregroundStyle(theme.color(.textStrong)).monospacedDigit()
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline) { label.fixedSize(); Spacer(minLength: 10); text.fixedSize() }
      VStack(alignment: .leading, spacing: 4) { label; text.padding(.leading, 28) }
    }
    .appFont(.secondary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title + ": " + value + (cause.map { ", " + $0 } ?? ""))
    .accessibilityIdentifier(id)
  }

  static func names(_ names: [String]) -> String {
    guard let first = names.first else { return "" }
    return names.count == 1 ? first : first + " e mais \(names.count - 1)"
  }

  static func cause(_ cause: SubscriptionDetails.Cause) -> String {
    switch cause {
    case .fiveHour: "janela de 5 horas"
    case .wait: "espera do proxy"
    case .unexplained: "recusa sem causa informada"
    }
  }

  #if DEBUG
  /// What the UI tests read, like the strip's: every plan with each account's mark (`Pro Max:R|Pro 5x:BE`).
  static func fixture(_ marks: SubscriptionMarks) -> String {
    marks.groups.map { group in
      group.title + ":" + group.accounts.map { account in
        switch SubscriptionMarks.Kind(account.mark) {
        case .ready: "R"
        case .blocked: "B"
        case .exhausted: "E"
        case .unmeasured: "?"
        case .attention: "!"
        }
      }.joined()
    }.joined(separator: "|")
  }
  #endif
}

/// A plan: its name and how many of its accounts are ready, then a card per account; accounts with nothing but a
/// name and a state (Free today) share one card after the others.
private struct ProxyPlanSection: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  let group: SubscriptionDetails.Group

  var body: some View {
    let full = group.accounts.filter { !$0.compact }
    let compact = group.accounts.filter(\.compact)
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(group.title.uppercased()).appFont(.secondary, weight: .bold).foregroundStyle(theme.color(.textStrong))
          .layoutPriority(1)
        Spacer(minLength: 0)
        count.appFont(.secondary).foregroundStyle(theme.color(.text)).multilineTextAlignment(.trailing)
      }
      .padding(.top, 6)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("proxy-plan-" + (group.plan ?? "nenhum"))
      ForEach(full) { row in ProxyAccountDetail(store: store, provider: provider, row: row) }
      if !compact.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(compact.enumerated()), id: \.element.id) { index, row in
            if index > 0 { Rectangle().fill(theme.color(.border)).frame(height: 0.5).padding(.vertical, 2) }
            ProxyCompactAccount(store: store, provider: provider, row: row)
          }
        }
        .proxyDetailCard(theme)
      }
    }
  }

  private var count: Text {
    let enabled = group.enabled.count
    let disabled = group.disabled == 0 ? "" : " · \(group.disabled) \(group.disabled == 1 ? "desativada" : "desativadas")"
    if group.unmeasured { return Text("\(enabled) sem medição" + disabled) }
    if enabled == 0 { return Text(String(disabled.dropFirst(3))) }
    let back = group.release.map { first in
      let count = group.enabled.filter { row in
        if case .blocked(let until?) = row.mark { return until.timeIntervalSince(first) < 60 }
        return false
      }.count
      return " · +\(count) " + (Calendar.current.isDate(first, inSameDayAs: store.now) ? "às " : "") + SubscriptionFormat.moment(first, now: store.now)
    } ?? ""
    let ready = Text("\(group.ready)").foregroundStyle(theme.color(group.ready > 0 ? .primary : .textStrong)).fontWeight(.semibold)
    return Text("\(ready) de \(enabled) \(enabled == 1 ? "pronta" : "prontas")\(back + disabled)")
  }
}

/// One account: name and state, its 5-hour and weekly windows side by side in columns, why it is stopped when the
/// windows do not say, then its credits, resets and actions.
private struct ProxyAccountDetail: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .title2) private var glyph = 17.0
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  let row: SubscriptionDetails.Account
  private var resetting: Bool { store.resetting.contains(provider.rawValue + ":" + row.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 8) { identity; Spacer(minLength: 8); ProxyStateBadge(row: row, now: store.now) }
        VStack(alignment: .leading, spacing: 8) { identity; ProxyStateBadge(row: row, now: store.now) }
      }
      if row.fiveHour != nil || row.weekly != nil {
        if dynamicTypeSize >= .xxLarge {
          VStack(alignment: .leading, spacing: 12) {
            if let window = row.fiveHour { stacked("5 horas", window) }
            if let window = row.weekly { stacked("Semana", window) }
          }
        } else {
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            if let window = row.fiveHour { gridRow("5 horas", window) }
            if let window = row.weekly { gridRow("Semana", window) }
          }
          .appFont(.secondary)
          // The columns line up across both rows; VoiceOver reads one element per window.
          .accessibilityElement(children: .contain)
          .accessibilityChildren {
            if let window = row.fiveHour { windowElement("5 horas", window) }
            if let window = row.weekly { windowElement("Semana", window) }
          }
        }
      }
      if let cause = cause {
        Label(cause, systemImage: "info.circle").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      }
      Rectangle().fill(theme.color(.border)).frame(height: 0.5)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 12) { facts; Spacer(minLength: 8); ProxyPinButton(store: store, provider: provider, row: row); reset }
        VStack(alignment: .leading, spacing: 10) {
          facts
          HStack(spacing: 12) { ProxyPinButton(store: store, provider: provider, row: row); Spacer(minLength: 8); reset }
        }
      }
      if resetting {
        Text("Aguardando o proxy · pode levar cerca de 90 segundos").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      }
    }
    .proxyDetailCard(theme)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("proxy-account-" + row.id)
  }

  private var identity: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      ProxyAccountGlyph(row: row, size: glyph)
      Text(row.name).appFont(.title, weight: .semibold).foregroundStyle(theme.color(.textStrong))
        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var cause: String? {
    switch row.cause {
    case .wait:
      if case .blocked(let until?) = row.mark { return "Em espera no proxy até " + SubscriptionFormat.moment(until, now: store.now) }
      return "Em espera no proxy, sem horário informado"
    case .unexplained: return "O proxy recusou sem indicar qual janela"
    default: return nil
    }
  }

  private func gridRow(_ name: String, _ window: SubscriptionDetails.Window) -> GridRow<some View> {
    GridRow(alignment: .center) {
      Text(name).foregroundStyle(theme.color(.text)).fixedSize()
      ProxyWindowBar(window: window, week: name == "Semana").frame(minWidth: 28)
      percent(name, window).gridColumnAlignment(.trailing)
      time(name, window).fixedSize()
    }
  }

  private func windowElement(_ name: String, _ window: SubscriptionDetails.Window) -> some View {
    Text(spoken(name, window)).accessibilityIdentifier("proxy-window-" + (name == "Semana" ? "week-" : "5h-") + row.id)
  }

  private func stacked(_ name: String, _ window: SubscriptionDetails.Window) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) { Text(name).foregroundStyle(theme.color(.text)); Spacer(); percent(name, window) }
      ProxyWindowBar(window: window, week: name == "Semana")
      time(name, window)
    }
    .appFont(.secondary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken(name, window))
    .accessibilityIdentifier("proxy-window-" + (name == "Semana" ? "week-" : "5h-") + row.id)
  }

  private func percent(_ name: String, _ window: SubscriptionDetails.Window) -> some View {
    Text(SubscriptionFormat.percent(window.remaining)).fontWeight(.semibold).monospacedDigit()
      .foregroundStyle(theme.color(ProxyWindowBar.role(window, week: name == "Semana")))
  }

  private func time(_ name: String, _ window: SubscriptionDetails.Window) -> some View {
    let moment = window.resetAt.map { SubscriptionFormat.moment($0, now: store.now) }
    let today = window.resetAt.map { Calendar.current.isDate($0, inSameDayAs: store.now) } ?? false
    let text = moment.map { moment in
      if window.blocking { return (name == "Semana" ? "renova " : "libera ") + moment }
      return today ? "renova " + moment : moment
    } ?? "sem horário"
    return Text(text).monospacedDigit()
      .fontWeight(window.blocking && name != "Semana" ? .semibold : .regular)
      .foregroundStyle(theme.color(window.blocking && name != "Semana" ? .warning : moment == nil ? .textSecondary : .text))
  }

  private func spoken(_ name: String, _ window: SubscriptionDetails.Window) -> String {
    let value = window.remaining.map { "\(SubscriptionFormat.percent($0)) restantes" } ?? "sem medição"
    let when = window.resetAt.map { (window.blocking && name != "Semana" ? ", libera " : ", renova ") + SubscriptionFormat.date($0) } ?? ""
    return name + ": " + value + when
  }

  /// Credits and resets of this account only.
  private var facts: some View {
    let credits = row.account.credits.map { "Créditos pagos " + SubscriptionFormat.number($0, decimals: 0) }
    let resets = row.account.bankedResets.map { inventory in
      SubscriptionFormat.resets(inventory.available) + (inventory.available > 0
        ? " · " + (inventory.earliestExpiresAt.map { "expira em " + SubscriptionFormat.countdown(Subscriptions.date($0), now: store.now) } ?? "sem expiração")
        : "")
    } ?? "Redefinições: inventário desconhecido"
    return Text([credits, resets].compactMap { $0 }.joined(separator: " · "))
      .appFont(.caption).foregroundStyle(theme.color(.textSecondary)).fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var reset: some View {
    if (row.account.bankedResets?.available ?? 0) > 0 {
      Button { store.requestReset(provider, account: row.account) } label: {
        Text(resetting ? "Aplicando…" : "Usar redefinição").appFont(.secondary, weight: .medium)
          .foregroundStyle(theme.color(.primary)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .overlay { Capsule().strokeBorder(theme.color(.primary), lineWidth: 1) }
          .contentShape(Capsule())
      }
      .buttonStyle(.plain).disabled(resetting)
      .accessibilityLabel(resetting ? "Aplicando redefinição de \(row.name)" : "Usar redefinição de \(row.name)")
      .accessibilityIdentifier("proxy-reset-" + row.id)
    }
  }
}

/// An account with nothing to show but its name and state (Free accounts the proxy does not measure).
private struct ProxyCompactAccount: View {
  @Environment(\.appTheme) private var theme
  @ScaledMetric(relativeTo: .headline) private var glyph = 15.0
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  let row: SubscriptionDetails.Account

  var body: some View {
    let name = HStack(spacing: 10) {
      ProxyAccountGlyph(row: row, size: glyph)
      Text(row.name).appFont(.heading).foregroundStyle(theme.color(.textStrong)).lineLimit(3)
    }
    let state = Text(ProxyStateBadge.title(row, now: store.now)).appFont(.secondary)
      .foregroundStyle(theme.color(ProxyStateBadge.role(row)))
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        name
        Spacer(minLength: 8)
        state.fixedSize()
        ProxyPinButton(store: store, provider: provider, row: row, iconOnly: true)
      }
      VStack(alignment: .leading, spacing: 4) {
        name
        HStack { state; Spacer(minLength: 8); ProxyPinButton(store: store, provider: provider, row: row, iconOnly: true) }
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("proxy-account-" + row.id)
  }
}

/// The strip's mark of the account, or a pause sign for a disabled one (the strip leaves those out).
private struct ProxyAccountGlyph: View {
  @Environment(\.appTheme) private var theme
  let row: SubscriptionDetails.Account
  let size: Double
  var body: some View {
    if let mark = row.mark {
      SubscriptionMarkGlyph(kind: .init(mark), pinned: row.pinned, size: size)
    } else {
      Image(systemName: "pause.circle").font(.system(size: size, weight: .semibold))
        .foregroundStyle(theme.color(.textSecondary)).frame(width: size + 2, height: size + 2).accessibilityHidden(true)
    }
  }
}

/// The state in words beside the mark, so it never depends on color: `Pronta`, `Parada até 11:15`, `Semana
/// esgotada`, `Sem medição`, `Precisa de login`, `Desativada`.
private struct ProxyStateBadge: View {
  @Environment(\.appTheme) private var theme
  let row: SubscriptionDetails.Account
  let now: Date
  var body: some View {
    let role = Self.role(row)
    Text(Self.title(row, now: now)).appFont(.secondary, weight: .medium).foregroundStyle(theme.color(role))
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(theme.color(role == .textSecondary ? .highlight : role).opacity(role == .textSecondary ? 1 : 0.16),
                  in: RoundedRectangle(cornerRadius: 14))
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("proxy-state-" + row.id)
  }

  static func title(_ row: SubscriptionDetails.Account, now: Date) -> String {
    guard let mark = row.mark else { return "Desativada" }
    switch mark {
    case .ready: return "Pronta"
    case .blocked(let until): return until.map { "Parada até " + SubscriptionFormat.moment($0, now: now) } ?? "Parada"
    case .exhausted: return "Semana esgotada"
    case .unmeasured: return "Sem medição"
    case .attention: return "Precisa de login"
    }
  }

  static func role(_ row: SubscriptionDetails.Account) -> ThemeRole {
    switch row.mark {
    case .ready: .primary
    case .blocked: .warning
    case .exhausted, .attention: .error
    case .unmeasured, nil: .textSecondary
    }
  }
}

/// "Destacar no resumo": rings this account's mark in the Sessões strip, among the others. The same preference as the
/// former "Mostrar no resumo" (`OpenCodeSubscriptionSelection.v1`); a second tap removes it.
private struct ProxyPinButton: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  let row: SubscriptionDetails.Account
  var iconOnly = false
  var body: some View {
    let pinned = row.pinned
    Button {
      store.toggleSelection(row.account, provider: provider)
      Haptics.play(.selection)
    } label: {
      Group {
        if iconOnly {
          Image(systemName: pinned ? "pin.fill" : "pin").frame(minWidth: 32, minHeight: 32)
        } else {
          Label(pinned ? "Destacada no resumo" : "Destacar no resumo", systemImage: pinned ? "pin.fill" : "pin")
            .appFont(.caption, weight: pinned ? .medium : .regular).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 32)
        }
      }
      .foregroundStyle(theme.color(pinned ? .primary : .text)).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(pinned ? "\(row.name) destacada no resumo" : "Destacar \(row.name) no resumo")
    .accessibilityAddTraits(pinned ? .isSelected : [])
    .accessibilityHint("Marca a conta na faixa de Sessões, sem esconder as outras. Não muda a conta usada pelo modelo.")
    .accessibilityIdentifier("proxy-select-" + row.id)
  }
}

/// A window's bar: the remaining share in the text color, amber or red only when it runs low or keeps the account
/// out; empty (not zero) when unknown.
private struct ProxyWindowBar: View {
  @Environment(\.appTheme) private var theme
  let window: SubscriptionDetails.Window
  let week: Bool
  var body: some View {
    GeometryReader { geometry in
      Capsule().fill(theme.color(.highlight)).overlay(alignment: .leading) {
        Capsule().fill(theme.color(Self.role(window, week: week)))
          .frame(width: geometry.size.width * min(1, max(0, (window.remaining ?? 0) / 100)))
      }
    }
    .frame(height: 8).accessibilityHidden(true)
  }

  static func role(_ window: SubscriptionDetails.Window, week: Bool) -> ThemeRole {
    guard let value = window.remaining else { return .textSecondary }
    if window.blocking { return week ? .error : .warning }
    switch SubscriptionFormat.tone(value) {
    case .danger: return .error
    case .warning: return .warning
    default: return .textStrong
    }
  }
}

/// The provider's resets: the sum of the inventories the accounts report (a count, never quota), and the automatic
/// reset switch.
private struct ProxyDetailResetsCard: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  let resets: SubscriptionDetails.Resets
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Redefinições").appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
      Text(summary).appFont(.secondary).foregroundStyle(theme.color(.text)).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("proxy-resets-summary")
      ProxyAutomationToggle(store: store, provider: provider)
    }
    .proxyDetailCard(theme)
  }

  private var summary: String {
    guard resets.accounts > 0 else { return "Inventário desconhecido" }
    let available = SubscriptionFormat.number(resets.available, decimals: 0)
    var parts = ["\(available) \(resets.available == 1 ? "disponível" : "disponíveis") em \(resets.accounts) \(resets.accounts == 1 ? "conta" : "contas")"]
    if let earliest = resets.earliest { parts.append("primeira expira " + SubscriptionFormat.moment(earliest, now: store.now)) }
    if resets.unknown > 0 { parts.append("\(resets.unknown) sem inventário") }
    return parts.joined(separator: " · ")
  }
}

extension View {
  /// The details' cards: the theme's surface, no outline.
  fileprivate func proxyDetailCard(_ theme: AppTheme) -> some View {
    padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 18))
  }
}
