import OpenCodeKit
import SwiftUI

struct ContextUsageRing: View {
  @Environment(\.appTheme) private var theme
  let usage: ContextUsage
  var size: CGFloat = 12
  var body: some View {
    ZStack {
      Circle().stroke(theme.color(.contextTrack), lineWidth: size / 6)
      Circle().trim(from: 0, to: usage.drawnFraction)
        .stroke(theme.color(usage.warning ? .contextWarning : .contextFill),
          style: StrokeStyle(lineWidth: size / 6, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}

struct ContextUsageLine: View {
  @Environment(\.appTheme) private var theme
  let usage: ContextUsage
  var compact = false
  var style: AppTextStyle = .caption
  var body: some View {
    ViewThatFits(in: .horizontal) {
      line
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 5) {
          ContextUsageRing(usage: usage, size: style == .metrics ? 10 : 12)
          Text(compact ? usage.shortContextLabel : usage.contextLabel)
          if !compact { Text("· " + usage.tokenLabel) }
        }
        Label(usage.cacheLabel, systemImage: "bolt.fill")
      }
    }
    .appFont(style).monospacedDigit().foregroundStyle(theme.color(.textSecondary))
    .accessibilityElement(children: .ignore).accessibilityLabel(usage.accessibilityLabel)
  }
  private var line: some View {
    HStack(spacing: 5) {
      ContextUsageRing(usage: usage, size: style == .metrics ? 10 : 12)
      Text(compact ? usage.shortContextLabel : usage.contextLabel)
      if !compact { Text("· " + usage.tokenLabel) }
      Text("·")
      Image(systemName: "bolt.fill").appFont(style)
      Text(usage.cacheLabel)
    }.fixedSize(horizontal: true, vertical: false)
  }
}

#if os(iOS)
struct SessionUsageSection: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  var body: some View {
    Section("Uso da sessão") {
      VStack(alignment: .leading, spacing: 9) {
        HStack {
          Text("Contexto")
          Spacer()
          if let usage = store.sessionUsage {
            Text(usage.tokenLabel).foregroundStyle(theme.color(.textSecondary))
            if let fraction = usage.fraction { Text(ContextUsage.percent(fraction)).fontWeight(.semibold) }
          } else {
            Text("Sem medição").foregroundStyle(theme.color(.textSecondary))
          }
        }
        if let usage = store.sessionUsage {
          if usage.fraction != nil {
            GeometryReader { geometry in
              Capsule().fill(theme.color(.contextTrack))
                .overlay(alignment: .leading) {
                  Capsule().fill(theme.color(usage.warning ? .contextWarning : .contextFill))
                    .frame(width: geometry.size.width * usage.drawnFraction)
                }
            }.frame(height: 5).accessibilityHidden(true)
          }
          Text("Último passo medido").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        }
      }.accessibilityElement(children: .ignore)
        .accessibilityLabel(store.sessionUsage?.contextAccessibilityLabel ?? "Contexto sem medição")
        .accessibilityIdentifier("session-usage-context")
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Label("Cache", systemImage: "bolt.fill")
          Spacer()
          Text(store.totalUsage?.cachePercentLabel ?? "—")
            .fontWeight(.semibold)
        }
        if let usage = store.totalUsage {
          Text("\(usage.cacheReadLabel) lidos · \(usage.cacheWriteLabel) gravados")
            .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        }
      }.accessibilityIdentifier("session-usage-cache")
      LabeledContent("Tokens", value: store.totalUsage?.totalLabel ?? "—")
        .accessibilityIdentifier("session-usage-tokens")
      LabeledContent("Custo", value: ContextUsage.money(store.session?.cost))
        .accessibilityIdentifier("session-usage-cost")
      if let familyCost = store.family?.cost, (store.family?.count ?? 0) > 0 {
        LabeledContent("Subagentes", value: ContextUsage.money(familyCost))
        LabeledContent("Custo total", value: ContextUsage.money(store.session?.cost.map { $0 + familyCost }))
      }
    }.listRowBackground(theme.color(.toolSurface))
  }
}
#endif

/// `◔ 71% · 711,3k / 1M · ⚡ 99,0% · US$ 26,95 · 20m · ☑ 2/4`, in the order `ContextColumn.metrics` gives: the Mac's
/// Contexto and the iPhone's "Agentes e tarefas" subagent lines.
struct ContextMetricsLine: View {
  @Environment(\.appTheme) private var theme
  let metrics: [ContextColumn.Metric]
  let usage: ContextUsage?

  var body: some View {
    HStack(alignment: .center, spacing: 5) {
      ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
        if index > 0 { Text("·").foregroundStyle(theme.color(.textWeak)) }
        item(metric)
      }
    }
    .appFont(.footnote).monospacedDigit().lineLimit(1)
  }

  @ViewBuilder private func item(_ metric: ContextColumn.Metric) -> some View {
    switch metric.kind {
    case .context:
      HStack(spacing: 4) {
        if let usage { ContextUsageRing(usage: usage, size: 10) }
        Text(metric.text).foregroundStyle(theme.color(.text))
      }
    case .cache:
      HStack(spacing: 2) {
        Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(theme.color(.textSecondary))
        Text(metric.text).foregroundStyle(theme.color(metric.warning ? .warning : .text))
      }
    case .progress:
      HStack(spacing: 3) {
        Image(systemName: "checklist").font(.system(size: 9)).foregroundStyle(theme.color(.textSecondary))
        Text(metric.text).foregroundStyle(theme.color(.text))
      }
      .accessibilityLabel("Progresso \(metric.text)")
    case .cost: Text(metric.text).foregroundStyle(theme.color(.textStrong))
    case .tokens, .elapsed: Text(metric.text).foregroundStyle(theme.color(.textSecondary))
    }
  }
}
