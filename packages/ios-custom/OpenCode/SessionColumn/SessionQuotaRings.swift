import OpenCodeKit
import SwiftUI

/// One ring per LLM proxy provider, in `providers` order. Each opens the provider's subscription details.
struct SessionQuotaRings: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let quota: SubscriptionStore
  let open: (SubscriptionProvider) -> Void

  var body: some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(spacing: 16))
    layout {
      ForEach(quota.providers) { provider in
        Button { open(provider) } label: {
          SessionQuotaRing(
            summary: quota.summary(provider), now: quota.now,
            name: quota.selected(provider).map { provider.title + " · " + $0.name } ?? provider.title)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("proxy-strip-" + provider.rawValue)
        .accessibilityHint("Ver contas, limites e renovações do LLM proxy")
      }
    }
  }
}

private struct SessionQuotaRing: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .subheadline) private var size = 38.0
  let summary: Subscriptions.Summary?
  let now: Date
  let name: String

  var body: some View {
    let percent = SubscriptionFormat.percent(summary?.remaining)
    let renewal = summary?.reset.map { SubscriptionFormat.countdown($0, now: now) }
    HStack(spacing: 10) {
      QuotaRing(remaining: summary?.remaining, ready: summary?.ready == true, lineWidth: 5)
        .frame(width: size, height: size)
      VStack(alignment: .leading, spacing: 1) {
        Text("\(name) \(percent)").appFont(.secondary, weight: .medium).foregroundStyle(theme.color(.textStrong))
          .truncationMode(.middle)
        Text(renewal.map { "renova " + $0 } ?? "renovação —").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary))
      }
      .monospacedDigit()
      .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(name), \(summary?.remaining == nil ? "cota indisponível" : percent + " restantes")\(renewal.map { ", renova em " + $0 } ?? "")\(summary?.ready == false ? ", sem conta pronta" : "")"
    )
  }
}

/// The quota ring: the remaining share, orange while an account is ready and amber otherwise.
struct QuotaRing: View {
  @Environment(\.appTheme) private var theme
  let remaining: Double?
  let ready: Bool
  let lineWidth: Double

  var body: some View {
    ZStack {
      Circle().stroke(theme.color(.highlight), lineWidth: lineWidth)
      Circle().trim(from: 0, to: min(1, max(0, (remaining ?? 0) / 100)))
        .stroke(theme.color(ready ? .primary : .warning), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .padding(lineWidth / 2)
  }
}
