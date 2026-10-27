import OpenCodeKit
import SwiftUI

func proxyRole(_ tone: SubscriptionTone) -> ThemeRole {
  switch tone {
  case .neutral: .textSecondary
  case .success: .success
  case .warning: .warning
  case .danger: .error
  }
}

struct SubscriptionCompactRow: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  var body: some View {
    let pool = store.projection(provider, compact: true)
    let selected = store.selected(provider)
    let ready = store.snapshot?.pool(provider).status == "ok"
    HStack(alignment: .top, spacing: 12) {
      ProxyProviderIcon(provider: provider).frame(width: 28, height: 32)
      VStack(alignment: .leading, spacing: 7) {
        HStack(alignment: .firstTextBaseline) {
          Text(provider.title).font(.headline).foregroundStyle(theme.color(.textStrong))
          Spacer(minLength: 4)
          if store.snapshot == nil { ProgressView().controlSize(.small) }
          else {
            Text(ready ? selected == nil
                 ? "\(SubscriptionFormat.number(pool.equivalents)) \(provider.unit)"
                 : SubscriptionFormat.percent(pool.remaining) : "Indisponível")
              .font(.subheadline).foregroundStyle(theme.color(.textSecondary))
          }
          Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.color(.icon))
        }
        if let selected {
          Text(Subscriptions.planLabel(selected.plan) + " · " + selected.name)
            .font(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(2)
        } else {
          Text(ready ? "\(SubscriptionFormat.percent(pool.remaining)) da cota semanal" : "Ver contas, limites e renovações")
            .font(.caption).foregroundStyle(theme.color(.textSecondary))
        }
        ProxyQuotaBar(value: ready ? pool.remaining : nil, label: "Cota semanal combinada", pace: pool.expectedRemaining)
        if provider == .anthropic, ready, let value = pool.fiveHourRemaining {
          Text("5 horas · \(SubscriptionFormat.percent(value))").font(.caption)
            .foregroundStyle(theme.color(proxyRole(SubscriptionFormat.tone(value))))
        }
      }
    }.padding(.vertical, 5).contentShape(Rectangle())
  }
}

struct SubscriptionDetailSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var store: SubscriptionStore
  let initialProvider: SubscriptionProvider
  @State private var provider = SubscriptionProvider.codex
  private var activeProvider: SubscriptionProvider { store.providers.contains(provider) ? provider : .codex }
  private var accounts: [Subscriptions.Account] {
    SubscriptionProjection.sorted(store.snapshot?.pool(activeProvider).accounts ?? [], now: store.now)
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Text("LLM proxy").font(.largeTitle.bold()).foregroundStyle(theme.color(.textStrong))
          Spacer(minLength: 0)
          Button { Task { await store.refresh() } } label: {
            if store.loading { ProgressView().frame(width: 26, height: 26) }
            else { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
          }.adaptiveGlassButtonStyle().buttonBorderShape(.circle).disabled(store.loading)
            .accessibilityLabel("Atualizar LLM proxy").accessibilityIdentifier("proxy-refresh")
          Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
            .adaptiveGlassButtonStyle(prominent: true).buttonBorderShape(.circle).tint(theme.color(.primary))
            .foregroundStyle(theme.color(.onPrimary)).accessibilityLabel("Fechar").accessibilityIdentifier("proxy-close")
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 8)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if store.providers.count > 1 {
            Picker("Provedor", selection: $provider) {
              ForEach(store.providers) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("proxy-provider")
          }
          content
        }.padding(16)
      }.background(theme.color(.background)).accessibilityIdentifier("proxy-detail")
        .refreshable { await store.refresh() }
      }.background(theme.color(.background))
      #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
      #endif
        .proxyActions(store)
    }.presentationDetents([.large]).presentationDragIndicator(.visible)
      .task { provider = initialProvider; await store.refresh(ifDue: true) }
  }

  @ViewBuilder private var content: some View {
    if store.snapshot?.pool(activeProvider).status == "ok", !accounts.isEmpty {
      ProxyPoolHeader(store: store, provider: activeProvider, accounts: accounts)
      ForEach(SubscriptionGroup.groups(accounts, provider: activeProvider, now: store.now)) { group in
        if group.opensOthers {
          Text("Outros planos · fora do saldo acima").font(.headline)
            .foregroundStyle(theme.color(.textSecondary)).padding(.top, 4)
        }
        HStack {
          Text(Subscriptions.planLabel(group.plan).uppercased()).font(.caption.weight(.semibold))
          Spacer()
          Text("\(group.projection.ready)/\(group.count) disponíveis").font(.caption)
        }.foregroundStyle(theme.color(.textSecondary))
        ForEach(group.rows) { row in
          ProxyAccountCard(store: store, provider: activeProvider, account: row.account) {
            store.toggleSelection(row.account, provider: activeProvider)
            Haptics.play(.selection)
            dismiss()
          }
        }
      }
      Label("A seleção altera só o resumo, não a conta usada pelo modelo.", systemImage: "info.circle")
        .font(.footnote).foregroundStyle(theme.color(.textSecondary))
      ProxyResetsCard(store: store, provider: activeProvider)
      Text(store.projection(activeProvider).freshness(now: store.now)).font(.caption).foregroundStyle(theme.color(.textWeak))
        .accessibilityIdentifier("proxy-updated")
    } else {
      ProxyPoolState(store: store, provider: activeProvider)
    }
  }
}

/// Loading, an unconfigured or unavailable proxy, and a provider without accounts.
struct ProxyPoolState: View {
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  var body: some View {
    if let snapshot = store.snapshot {
      let data = snapshot.pool(provider)
      if data.status == "ok" {
        ContentUnavailableView("Nenhuma conta", systemImage: "person.crop.circle.badge.questionmark",
                               description: Text("Nenhuma assinatura foi informada pelo LLM proxy."))
      } else {
        ContentUnavailableView {
          Label(data.status == "unconfigured" ? "LLM proxy não configurado" : "LLM proxy indisponível", systemImage: "network")
        } description: {
          Text(data.status == "unconfigured" ? "Configure o LLM proxy no servidor OpenCode para consultar as assinaturas."
               : store.readError ?? "Não foi possível consultar este provedor. Os outros provedores e suas sessões continuam disponíveis.")
        } actions: { Button("Tentar novamente") { Task { await store.refresh() } }.disabled(store.loading) }
      }
    } else { ProgressView("Consultando o LLM proxy…").frame(maxWidth: .infinity).padding(.vertical, 40) }
  }
}

/// The pool card: combined weekly balance, availability, next renewal, plans and paid credits. `wide` is the
/// Mac window's layout, with the logo beside the text and the renewal on the right.
struct ProxyPoolHeader: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  let accounts: [Subscriptions.Account]
  var wide = false
  private var plans: [String?] {
    accounts.reduce(into: [String?]()) { if !$0.contains($1.plan) { $0.append($1.plan) } }
  }
  var body: some View {
    let pool = store.projection(provider)
    Group {
      if wide {
        HStack(alignment: .top, spacing: 16) {
          ProxyProviderIcon(provider: provider).frame(width: 36, height: 36)
          VStack(alignment: .leading, spacing: 8) {
            Text(provider.title).font(.title3.bold())
            balance(pool)
            details
          }
          Spacer(minLength: 24)
          VStack(alignment: .leading, spacing: 10) {
            fiveHour(pool)
            renewal(pool)
          }.frame(minWidth: 220, alignment: .leading)
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            ProxyProviderIcon(provider: provider).frame(width: 28, height: 28)
            Text(provider.title).font(.title2.bold())
            Spacer(minLength: 0)
            fiveHour(pool)
          }
          if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) { balance(pool); renewal(pool) }
          } else {
            HStack(alignment: .top, spacing: 18) { balance(pool); renewal(pool) }
          }
          details
        }
      }
    }.proxyCard(theme).accessibilityIdentifier("proxy-pool-header")
  }
  @ViewBuilder private func fiveHour(_ pool: SubscriptionProjection) -> some View {
    if provider == .anthropic, let value = pool.fiveHourRemaining {
      Text("5 horas · \(SubscriptionFormat.percent(value))").font(.caption.weight(.medium))
        .proxyBadge(SubscriptionFormat.tone(value), theme: theme)
    }
  }
  @ViewBuilder private var details: some View {
    let credits = accounts.compactMap(\.credits)
    Text("\(plans.map { Subscriptions.planLabel($0) }.joined(separator: " · ")) · \(accounts.count) contas")
      .font(.caption).foregroundStyle(theme.color(.textWeak))
    if !credits.isEmpty {
      Text("Créditos pagos · \(SubscriptionFormat.number(credits.reduce(0, +), decimals: 0))")
        .font(.caption).foregroundStyle(theme.color(.textSecondary))
    }
  }
  private func balance(_ pool: SubscriptionProjection) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("\(SubscriptionFormat.number(pool.equivalents)) \(provider.unit)")
        .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
      Text("Cota semanal combinada").font(.subheadline).foregroundStyle(theme.color(.textSecondary))
      if wide {
        HStack(spacing: 14) {
          ProxyQuotaBar(value: pool.remaining, label: "Cota semanal combinada", pace: pool.expectedRemaining)
            .frame(maxWidth: 360)
          remaining(pool)
        }
      } else {
        ProxyQuotaBar(value: pool.remaining, label: "Cota semanal combinada", pace: pool.expectedRemaining)
        remaining(pool)
      }
    }.frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
  }
  private func remaining(_ pool: SubscriptionProjection) -> some View {
    Text("\(SubscriptionFormat.percent(pool.remaining)) restantes").font(.subheadline)
      .foregroundStyle(theme.color(proxyRole(SubscriptionFormat.tone(pool.remaining))))
  }
  private func renewal(_ pool: SubscriptionProjection) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("\(pool.ready) de \(pool.total) \(pool.total == 1 ? "conta disponível" : "contas disponíveis")").font(.caption)
      Text("Próxima renovação").font(.caption).foregroundStyle(theme.color(.textSecondary))
      if wide {
        Text(SubscriptionFormat.date(pool.renewal) + " · " + SubscriptionFormat.countdown(pool.renewal, now: store.now)).font(.caption)
      } else {
        Text(SubscriptionFormat.date(pool.renewal)).font(.caption)
        Text(SubscriptionFormat.countdown(pool.renewal, now: store.now)).font(.caption).foregroundStyle(theme.color(.textWeak))
      }
    }.fixedSize(horizontal: false, vertical: true)
  }
}

/// A provider's banked resets (count, first and last expiry, how many never expire) and its automation switch.
struct ProxyResetsCard: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  var body: some View {
    let pool = store.projection(provider)
    VStack(alignment: .leading, spacing: 10) {
      Text("Redefinições").font(.headline)
      Text(pool.inventory.map { SubscriptionFormat.resets($0.available) + ($0.available == 1 ? " disponível" : " disponíveis") } ?? "Inventário desconhecido")
        .font(.subheadline).foregroundStyle(theme.color(.textSecondary))
      if let inventory = pool.inventory {
        if let earliest = inventory.earliest { Text("Primeira expiração · \(SubscriptionFormat.date(earliest))").font(.caption) }
        if let latest = inventory.latest, latest != inventory.earliest { Text("Última expiração · \(SubscriptionFormat.date(latest))").font(.caption) }
        if inventory.nonExpiring > 0 { Text("\(SubscriptionFormat.number(inventory.nonExpiring, decimals: 0)) sem expiração").font(.caption) }
      }
      ProxyAutomationToggle(store: store, provider: provider)
    }.foregroundStyle(theme.color(.textStrong)).proxyCard(theme)
  }
}

/// "Redefinição automática": the change waits for confirmation and shows "Aplicando…" while it runs.
struct ProxyAutomationToggle: View {
  @Environment(\.appTheme) private var theme
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  var body: some View {
    if let automation = store.snapshot?.pool(provider).automation {
      Toggle(isOn: Binding(get: { store.pending[provider] ?? automation.enabled },
                           set: { store.requestAutomation(provider, enabled: $0) })) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Redefinição automática").font(.subheadline)
          Text(store.pending[provider] != nil ? "Aplicando…" : automation.enabled ? "Ativada" : "Pausada")
            .font(.caption).foregroundStyle(theme.color(.textSecondary))
        }
      }
      // A deferred/denied change must also reset UISwitch's native optimistic value.
      .id("\(provider.rawValue):\(automation.enabled):\(store.pending[provider] != nil):\(store.confirmation?.id ?? "")")
      .disabled(store.pending[provider] != nil).accessibilityIdentifier("proxy-automation")
    } else { Text("Automação não informada pelo servidor").font(.caption) }
  }
}

extension View {
  /// The confirmation dialog of "Usar redefinição" and of the automation switch, and the toast with the result.
  func proxyActions(_ store: SubscriptionStore) -> some View { modifier(ProxyActions(store: store)) }
}

private struct ProxyActions: ViewModifier {
  let store: SubscriptionStore
  @State private var toast = ToastCenter()
  @State private var presentedConfirmation: SubscriptionStore.Confirmation?
  @State private var confirmationVisible = false
  func body(content: Content) -> some View {
    content
      .toastOverlay(toast)
      .onChange(of: store.feedback?.id) {
        guard let feedback = store.feedback else { return }
        toast.show(feedback.text, kind: feedback.failure ? .error : .success)
        Haptics.play(feedback.failure ? .warning : .success)
      }
      .onChange(of: store.confirmation?.id) {
        guard let confirmation = store.confirmation else { return }
        presentedConfirmation = confirmation
        confirmationVisible = true
      }
      .alert(presentedConfirmation?.title ?? "Confirmar ação", isPresented: $confirmationVisible) {
          Button(presentedConfirmation?.action ?? "Confirmar", role: .destructive) {
            // Keep the confirmed value after SwiftUI dismisses the dialog binding.
            store.confirmation = presentedConfirmation
            presentedConfirmation = nil
            Task { await store.confirm() }
          }.accessibilityIdentifier("proxy-confirm")
          Button("Cancelar", role: .cancel) { store.confirmation = nil; presentedConfirmation = nil }
        } message: { Text(presentedConfirmation?.message ?? "") }
  }
}

/// An account's card: windows, renewals, "Mostrar no resumo" and its banked resets. `wide` is the Mac window's
/// panel under the table, with the status and the resets on the right.
struct ProxyAccountCard: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  let account: Subscriptions.Account
  var wide = false
  let select: () -> Void
  private var weeklyExhausted: Bool { account.value(account.remaining, at: store.now) == 0 }
  private var hasFiveHour: Bool { !weeklyExhausted && (account.fiveHourRemaining != nil || account.fiveHourResetAt != nil) }
  private var resetting: Bool { store.resetting.contains(provider.rawValue + ":" + account.id) }
  var body: some View {
    Group {
      if wide {
        HStack(alignment: .top, spacing: 28) {
          VStack(alignment: .leading, spacing: 10) {
            identity
            windows.frame(maxWidth: 460)
            HStack(alignment: .top, spacing: 28) {
              if hasFiveHour { renewal("5 horas renovam", date: account.fiveHourResetAt) }
              renewal("Semana renova", date: account.resetAt)
            }
            selectButton
          }
          Spacer(minLength: 0)
          VStack(alignment: .trailing, spacing: 12) {
            status
            if let inventory = account.bankedResets {
              inventoryCount(inventory).multilineTextAlignment(.trailing).foregroundStyle(theme.color(.textSecondary))
              if inventory.available > 0 { resetButton.buttonStyle(.bordered) }
              if resetting { waiting.multilineTextAlignment(.trailing).frame(maxWidth: 220, alignment: .trailing) }
            } else { unknownInventory }
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) { identity; Spacer(minLength: 6); status }
            VStack(alignment: .leading, spacing: 8) { identity; status }
          }
          windows
          Rectangle().fill(theme.color(.border)).frame(height: 0.5)
          if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
              if hasFiveHour { renewal("5 horas renovam", date: account.fiveHourResetAt) }
              renewal("Semana renova", date: account.resetAt)
            }
          } else {
            HStack(alignment: .top, spacing: 12) {
              if hasFiveHour { renewal("5 horas renovam", date: account.fiveHourResetAt).frame(maxWidth: .infinity, alignment: .leading) }
              renewal("Semana renova", date: account.resetAt).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          selectButton
          inventory
        }
      }
    }.proxyCard(theme, selected: store.selectedIDs[provider] == account.id)
      .accessibilityElement(children: .contain).accessibilityLabel(account.name)
  }
  @ViewBuilder private var windows: some View {
    if weeklyExhausted {
      Text("Semana · 0%").font(.subheadline).foregroundStyle(theme.color(.error))
    } else {
      if hasFiveHour { window("5 horas", value: account.fiveHourRemaining) }
      window("Semana", value: account.remaining, pace: account.pace(at: store.now))
    }
  }
  private var selectButton: some View {
    Button(action: select) {
      Label("Mostrar no resumo", systemImage: store.selectedIDs[provider] == account.id ? "largecircle.fill.circle" : "circle")
        .font(.subheadline).foregroundStyle(theme.color(store.selectedIDs[provider] == account.id ? .primary : .text))
        .frame(minHeight: 32)
    }.buttonStyle(.plain).accessibilityIdentifier("proxy-select-" + account.id)
      .accessibilityAddTraits(store.selectedIDs[provider] == account.id ? .isSelected : [])
      .accessibilityLabel("Mostrar \(account.name) no resumo")
      .accessibilityHint("Altera somente a apresentação. Toque novamente para voltar ao pool.")
  }
  private var identity: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(account.name).font(.headline).foregroundStyle(theme.color(.textStrong)).fixedSize(horizontal: false, vertical: true)
      Text(Subscriptions.planLabel(account.plan)).font(.caption).foregroundStyle(theme.color(.textSecondary))
    }
  }
  private var status: some View {
    Label(account.state(at: store.now).title, systemImage: "circle.fill").font(.caption)
      .proxyBadge(account.state(at: store.now).tone, theme: theme)
  }
  private func window(_ name: String, value: Double?, pace: Double? = nil) -> some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          HStack { Text(name); Spacer(); Text(SubscriptionFormat.percent(account.value(value, at: store.now))) }
          ProxyQuotaBar(value: account.value(value, at: store.now), label: name + " de " + account.name, pace: pace)
        }
      } else {
        HStack(spacing: 10) {
          Text(name).frame(width: 56, alignment: .leading)
          ProxyQuotaBar(value: account.value(value, at: store.now), label: name + " de " + account.name, pace: pace)
          Text(SubscriptionFormat.percent(account.value(value, at: store.now))).monospacedDigit().frame(minWidth: 36, alignment: .trailing)
            .foregroundStyle(theme.color(proxyRole(SubscriptionFormat.tone(account.value(value, at: store.now)))))
        }
      }
    }.font(.subheadline).foregroundStyle(theme.color(.text))
  }
  private func renewal(_ label: String, date: String?) -> some View {
    Text(label + " " + SubscriptionFormat.date(Subscriptions.date(date)))
      .font(.caption).foregroundStyle(theme.color(.textSecondary)).fixedSize(horizontal: false, vertical: true)
  }
  @ViewBuilder private var inventory: some View {
    if let inventory = account.bankedResets {
      let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
      layout {
        inventoryCount(inventory)
        Spacer(minLength: 8)
        if inventory.available > 0 { resetButton }
      }.foregroundStyle(theme.color(.textSecondary))
      if resetting { waiting }
    } else { unknownInventory }
  }
  private func inventoryCount(_ inventory: Subscriptions.BankedResets) -> some View {
    VStack(alignment: wide ? .trailing : .leading, spacing: 4) {
      Text(SubscriptionFormat.resets(inventory.available))
      if inventory.available > 0 {
        Text(inventory.earliestExpiresAt.map { "Expira em " + SubscriptionFormat.countdown(Subscriptions.date($0), now: store.now) } ?? "Sem expiração")
          .foregroundStyle(theme.color(.textWeak))
      }
    }.font(.caption)
  }
  private var resetButton: some View {
    Button { store.requestReset(provider, account: account) } label: {
      if resetting { Label("Aplicando…", systemImage: "hourglass") }
      else { Label("Usar redefinição", systemImage: "arrow.clockwise") }
    }.font(.caption).disabled(resetting).accessibilityIdentifier("proxy-reset-" + account.id)
  }
  private var waiting: some View {
    Text("Aguardando o proxy · pode levar cerca de 90 segundos").font(.caption).foregroundStyle(theme.color(.textSecondary))
  }
  private var unknownInventory: some View {
    Text("Redefinições · inventário desconhecido").font(.caption).foregroundStyle(theme.color(.textWeak))
  }
}

struct ProxyProviderIcon: View {
  @Environment(\.appTheme) private var theme
  let provider: SubscriptionProvider
  var body: some View {
    Image(provider == .codex ? "ProxyOpenAI" : "ProxyAnthropic").renderingMode(.template).resizable().scaledToFit()
      .foregroundStyle(theme.color(provider == .codex ? .textStrong : .primary)).accessibilityHidden(true)
  }
}

struct ProxyQuotaBar: View {
  @Environment(\.appTheme) private var theme
  let value: Double?
  let label: String
  var pace: Double? = nil
  var body: some View {
    GeometryReader { geometry in
      Capsule().fill(theme.color(.highlight)).overlay(alignment: .leading) {
        Capsule().fill(theme.color(value.map { $0 < 10 ? .error : $0 < 30 ? .warning : .success } ?? .textWeak))
          .frame(width: geometry.size.width * min(1, max(0, (value ?? 0) / 100)))
      }.overlay(alignment: .leading) {
        if let pace {
          Rectangle().fill(theme.color(.textSecondary)).frame(width: 1)
            .offset(x: geometry.size.width * min(1, max(0, pace / 100)))
        }
      }
    }.frame(height: 7).accessibilityElement(children: .ignore).accessibilityLabel(label)
      .accessibilityValue(SubscriptionFormat.percent(value))
      .accessibilityHint(pace.map { "Ritmo semanal esperado: " + SubscriptionFormat.percent($0) } ?? "")
  }
}

extension View {
  func proxyCard(_ theme: AppTheme, selected: Bool = false) -> some View {
    padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 18))
      .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(selected ? .primary : .border), lineWidth: selected ? 1.2 : 0.75) }
      .foregroundStyle(theme.color(.textStrong))
  }
  func proxyBadge(_ tone: SubscriptionTone, theme: AppTheme) -> some View {
    foregroundStyle(theme.color(proxyRole(tone))).padding(.horizontal, 9).padding(.vertical, 5)
      .background(theme.color(tone == .neutral ? .highlight : proxyRole(tone)).opacity(tone == .neutral ? 1 : 0.12), in: Capsule())
      .fixedSize(horizontal: false, vertical: true)
  }
}
