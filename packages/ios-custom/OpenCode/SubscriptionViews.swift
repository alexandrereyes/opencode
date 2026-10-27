import OpenCodeKit
import SwiftUI

private func proxyRole(_ tone: SubscriptionTone) -> ThemeRole {
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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var store: SubscriptionStore
  let initialProvider: SubscriptionProvider
  @State private var provider = SubscriptionProvider.codex
  @State private var toast = ToastCenter()
  @State private var presentedConfirmation: SubscriptionStore.Confirmation?
  @State private var confirmationVisible = false
  private var activeProvider: SubscriptionProvider { store.providers.contains(provider) ? provider : .codex }
  private var accounts: [Subscriptions.Account] {
    SubscriptionProjection.sorted(store.snapshot?.pool(activeProvider).accounts ?? [], now: store.now)
  }
  private var plans: [String?] {
    accounts.reduce(into: [String?]()) { if !$0.contains($1.plan) { $0.append($1.plan) } }
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
        .alert(confirmationTitle, isPresented: $confirmationVisible) {
            Button(confirmationAction, role: .destructive) {
              // Keep the confirmed value after SwiftUI dismisses the dialog binding.
              store.confirmation = presentedConfirmation
              presentedConfirmation = nil
              Task { await store.confirm() }
            }.accessibilityIdentifier("proxy-confirm")
            Button("Cancelar", role: .cancel) { store.confirmation = nil; presentedConfirmation = nil }
          } message: { Text(confirmationMessage) }
    }.presentationDetents([.large]).presentationDragIndicator(.visible)
      .task { provider = initialProvider; await store.refresh(ifDue: true) }
  }

  @ViewBuilder private var content: some View {
    if let snapshot = store.snapshot {
      let data = snapshot.pool(activeProvider)
      if data.status == "ok" {
        if accounts.isEmpty {
          ContentUnavailableView("Nenhuma conta", systemImage: "person.crop.circle.badge.questionmark",
                                 description: Text("Nenhuma assinatura foi informada pelo LLM proxy."))
        } else {
          header
          ForEach(Array(plans.enumerated()), id: \.offset) { index, plan in
            let outside = !SubscriptionProjection.includes(plan, in: activeProvider.plan)
            if outside && (index == 0 || SubscriptionProjection.includes(plans[index - 1], in: activeProvider.plan)) {
              Text("Outros planos · fora do saldo acima").font(.headline)
                .foregroundStyle(theme.color(.textSecondary)).padding(.top, 4)
            }
            let group = accounts.filter { $0.plan == plan }
            let projection = SubscriptionProjection(accounts: group, plan: plan ?? "", now: store.now)
            HStack {
              Text(Subscriptions.planLabel(plan).uppercased()).font(.caption.weight(.semibold))
              Spacer()
              Text("\(projection.ready)/\(group.count) disponíveis").font(.caption)
            }.foregroundStyle(theme.color(.textSecondary))
            ForEach(group) { account in
              ProxyAccountCard(store: store, provider: activeProvider, account: account) {
                store.toggleSelection(account, provider: activeProvider)
                Haptics.play(.selection)
                dismiss()
              }
            }
          }
          Label("A seleção altera só o resumo, não a conta usada pelo modelo.", systemImage: "info.circle")
            .font(.footnote).foregroundStyle(theme.color(.textSecondary))
          automation
          Text(updated).font(.caption).foregroundStyle(theme.color(.textWeak))
            .accessibilityIdentifier("proxy-updated")
        }
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

  private var header: some View {
    let pool = store.projection(activeProvider)
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        ProxyProviderIcon(provider: activeProvider).frame(width: 28, height: 28)
        Text(activeProvider.title).font(.title2.bold())
        Spacer(minLength: 0)
        if activeProvider == .anthropic, let value = pool.fiveHourRemaining {
          Text("5 horas · \(SubscriptionFormat.percent(value))").font(.caption.weight(.medium))
            .proxyBadge(SubscriptionFormat.tone(value), theme: theme)
        }
      }
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 12) { balance(pool); renewal(pool) }
      } else {
        HStack(alignment: .top, spacing: 18) { balance(pool); renewal(pool) }
      }
      let credits = accounts.compactMap(\.credits)
      Text("\(plans.map { Subscriptions.planLabel($0) }.joined(separator: " · ")) · \(accounts.count) contas")
        .font(.caption).foregroundStyle(theme.color(.textWeak))
      if !credits.isEmpty {
        Text("Créditos pagos · \(SubscriptionFormat.number(credits.reduce(0, +), decimals: 0))")
          .font(.caption).foregroundStyle(theme.color(.textSecondary))
      }
    }.proxyCard(theme).accessibilityIdentifier("proxy-pool-header")
  }
  private func balance(_ pool: SubscriptionProjection) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("\(SubscriptionFormat.number(pool.equivalents)) \(activeProvider.unit)")
        .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
      Text("Cota semanal combinada").font(.subheadline).foregroundStyle(theme.color(.textSecondary))
      ProxyQuotaBar(value: pool.remaining, label: "Cota semanal combinada", pace: pool.expectedRemaining)
      Text("\(SubscriptionFormat.percent(pool.remaining)) restantes").font(.subheadline)
        .foregroundStyle(theme.color(proxyRole(SubscriptionFormat.tone(pool.remaining))))
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func renewal(_ pool: SubscriptionProjection) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("\(pool.ready) de \(pool.total) \(pool.total == 1 ? "conta disponível" : "contas disponíveis")").font(.caption)
      Text("Próxima renovação").font(.caption).foregroundStyle(theme.color(.textSecondary))
      Text(SubscriptionFormat.date(pool.renewal)).font(.caption)
      Text(SubscriptionFormat.countdown(pool.renewal, now: store.now)).font(.caption).foregroundStyle(theme.color(.textWeak))
    }.fixedSize(horizontal: false, vertical: true)
  }
  private var automation: some View {
    let pool = store.projection(activeProvider)
    return VStack(alignment: .leading, spacing: 10) {
      Text("Redefinições").font(.headline)
      Text(pool.inventory.map { SubscriptionFormat.resets($0.available) + ($0.available == 1 ? " disponível" : " disponíveis") } ?? "Inventário desconhecido")
        .font(.subheadline).foregroundStyle(theme.color(.textSecondary))
      if let inventory = pool.inventory {
        if let earliest = inventory.earliest { Text("Primeira expiração · \(SubscriptionFormat.date(earliest))").font(.caption) }
        if let latest = inventory.latest, latest != inventory.earliest { Text("Última expiração · \(SubscriptionFormat.date(latest))").font(.caption) }
        if inventory.nonExpiring > 0 { Text("\(SubscriptionFormat.number(inventory.nonExpiring, decimals: 0)) sem expiração").font(.caption) }
      }
      if let automation = store.snapshot?.pool(activeProvider).automation {
        Toggle(isOn: Binding(get: { store.pending[activeProvider] ?? automation.enabled },
                             set: { store.requestAutomation(activeProvider, enabled: $0) })) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Redefinição automática").font(.subheadline)
            Text(store.pending[activeProvider] != nil ? "Aplicando…" : automation.enabled ? "Ativada" : "Pausada")
              .font(.caption).foregroundStyle(theme.color(.textSecondary))
          }
        }
        // A deferred/denied change must also reset UISwitch's native optimistic value.
        .id("\(activeProvider.rawValue):\(automation.enabled):\(store.pending[activeProvider] != nil):\(store.confirmation?.id ?? "")")
        .disabled(store.pending[activeProvider] != nil).accessibilityIdentifier("proxy-automation")
      } else { Text("Automação não informada pelo servidor").font(.caption) }
    }.foregroundStyle(theme.color(.textStrong)).proxyCard(theme)
  }
  private var updated: String {
    let pool = store.projection(activeProvider)
    guard let observed = pool.observedAt else { return "\(pool.measured) de \(pool.total) medições confirmadas" }
    let minutes = max(0, Int(store.now.timeIntervalSince(observed) / 60))
    return minutes == 0 ? "Atualizado agora" : "Medição mais antiga · há \(minutes) min"
  }
  private var confirmationTitle: String {
    switch presentedConfirmation {
    case .automation(_, let enabled): enabled ? "Ativar redefinição automática?" : "Pausar redefinição automática?"
    case .reset: "Consumir uma redefinição?"
    case nil: "Confirmar ação"
    }
  }
  private var confirmationAction: String {
    switch presentedConfirmation {
    case .automation(_, let enabled): enabled ? "Ativar" : "Pausar"
    case .reset: "Consumir redefinição"
    case nil: "Confirmar"
    }
  }
  private var confirmationMessage: String {
    switch presentedConfirmation {
    case .automation(let provider, let enabled):
      enabled ? "O LLM proxy poderá consumir redefinições guardadas automaticamente para \(provider.title). Isso afeta todo o provedor no servidor."
        : "O LLM proxy deixará de consumir redefinições automaticamente para \(provider.title). Isso afeta todo o provedor no servidor."
    case .reset(_, let account):
      "Uma redefinição guardada de \(account.name) será consumida. A operação pode levar cerca de 90 segundos e não pode ser desfeita."
    case nil: ""
    }
  }
}

private struct ProxyAccountCard: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let store: SubscriptionStore
  let provider: SubscriptionProvider
  let account: Subscriptions.Account
  let select: () -> Void
  private var weeklyExhausted: Bool { account.value(account.remaining, at: store.now) == 0 }
  private var hasFiveHour: Bool { !weeklyExhausted && (account.fiveHourRemaining != nil || account.fiveHourResetAt != nil) }
  private var resetting: Bool { store.resetting.contains(provider.rawValue + ":" + account.id) }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top) { identity; Spacer(minLength: 6); status }
        VStack(alignment: .leading, spacing: 8) { identity; status }
      }
      if weeklyExhausted {
        Text("Semana · 0%").font(.subheadline).foregroundStyle(theme.color(.error))
      } else {
        if hasFiveHour { window("5 horas", value: account.fiveHourRemaining) }
        window("Semana", value: account.remaining, pace: account.pace(at: store.now))
      }
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
      Button(action: select) {
        Label("Mostrar no resumo", systemImage: store.selectedIDs[provider] == account.id ? "largecircle.fill.circle" : "circle")
          .font(.subheadline).foregroundStyle(theme.color(store.selectedIDs[provider] == account.id ? .primary : .text))
          .frame(minHeight: 32)
      }.buttonStyle(.plain).accessibilityIdentifier("proxy-select-" + account.id)
        .accessibilityAddTraits(store.selectedIDs[provider] == account.id ? .isSelected : [])
        .accessibilityLabel("Mostrar \(account.name) no resumo")
        .accessibilityHint("Altera somente a apresentação. Toque novamente para voltar ao pool.")
      inventory
    }.proxyCard(theme, selected: store.selectedIDs[provider] == account.id)
      .accessibilityElement(children: .contain).accessibilityLabel(account.name)
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
        VStack(alignment: .leading, spacing: 4) {
          Text(SubscriptionFormat.resets(inventory.available))
          if inventory.available > 0 {
            Text(inventory.earliestExpiresAt.map { "Expira em " + SubscriptionFormat.countdown(Subscriptions.date($0), now: store.now) } ?? "Sem expiração")
              .foregroundStyle(theme.color(.textWeak))
          }
        }.font(.caption)
        Spacer(minLength: 8)
        if inventory.available > 0 {
          Button { store.requestReset(provider, account: account) } label: {
            if resetting { Label("Aplicando…", systemImage: "hourglass") }
            else { Label("Usar redefinição", systemImage: "arrow.clockwise") }
          }.font(.caption).disabled(resetting).accessibilityIdentifier("proxy-reset-" + account.id)
        }
      }.foregroundStyle(theme.color(.textSecondary))
      if resetting { Text("Aguardando o proxy · pode levar cerca de 90 segundos").font(.caption).foregroundStyle(theme.color(.textSecondary)) }
    } else { Text("Redefinições · inventário desconhecido").font(.caption).foregroundStyle(theme.color(.textWeak)) }
  }
}

private struct ProxyProviderIcon: View {
  @Environment(\.appTheme) private var theme
  let provider: SubscriptionProvider
  var body: some View {
    Image(provider == .codex ? "ProxyOpenAI" : "ProxyAnthropic").renderingMode(.template).resizable().scaledToFit()
      .foregroundStyle(theme.color(provider == .codex ? .textStrong : .primary)).accessibilityHidden(true)
  }
}

private struct ProxyQuotaBar: View {
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

private extension View {
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
