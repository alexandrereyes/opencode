import OpenCodeKit
import SwiftUI

/// The Sessões quota strip, shared by the iPhone and the Mac: for each LLM proxy provider, in `providers` order, its
/// small icon, every enabled subscription as one mark, ready ones first as small rings with their own balance
/// (`SubscriptionMarks.runs`, which repeats a plan's label when the states split it), and how many are ready now.
/// It replaces the rings, which averaged one plan's weekly percent, within their row (38 pt), and keeps the 33 pt
/// of the marks before it: the providers side by side on two lines; where the marks do not fit side by side, one
/// line each (then without the release time); only then counts by state per plan, the ready share per plan, and the
/// provider's counts by state. A provider opens its subscription details.
struct SessionQuotaMarks: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let quota: SubscriptionStore
  let open: (SubscriptionProvider) -> Void

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 10) { providers(.adaptive) }
    } else {
      ViewThatFits(in: .horizontal) {
        SessionQuotaRow(spacing: 10) { providers(.marks) }
        // One line each: 1 pt apart keeps two 16 pt rings within today's 33 pt.
        VStack(alignment: .leading, spacing: 1) { providers(.line) }
        VStack(alignment: .leading, spacing: 1) { providers(.lineReady) }
        SessionQuotaRow(spacing: 10) { providers(.adaptive) }
      }
    }
  }

  private func providers(_ style: SessionQuotaProvider.Style) -> some View {
    ForEach(quota.providers) { provider in
      let row = SessionQuotaProvider(provider: provider, marks: quota.marks(provider),
        status: quota.snapshot?.pool(provider).status, now: quota.now, style: style)
      Button { open(provider) } label: { row }
      .buttonStyle(.plain)
      .accessibilityLabel(row.spoken)
      #if DEBUG
      .accessibilityValue(row.fixture)
      #endif
      .accessibilityIdentifier("proxy-strip-" + provider.rawValue)
      .accessibilityHint("Ver contas, limites e renovações do LLM proxy")
    }
  }
}

/// The providers side by side, each with room for what it shows: as even as the row allows when everything fits,
/// each one's narrowest form plus a share of the rest in proportion to what it needs beyond that when it does not,
/// so a provider with longer plan names keeps its marks while the other never overflows. Each provider then fits its
/// own content to that width.
private struct SessionQuotaRow: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let widths = allot(proposal.width, subviews)
    let height = zip(subviews, widths).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }.max() ?? 0
    return CGSize(width: proposal.width ?? widths.reduce(0, +) + gaps(subviews), height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    for (subview, width) in zip(subviews, allot(bounds.width, subviews)) {
      subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .init(width: width, height: nil))
      x += width + spacing
    }
  }

  private func gaps(_ subviews: Subviews) -> CGFloat { spacing * CGFloat(max(0, subviews.count - 1)) }

  private func allot(_ width: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
    let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
    guard let width, !ideal.isEmpty else { return ideal }
    let available = max(0, width - gaps(subviews))
    let total = ideal.reduce(0, +)
    guard total > available else {
      // Raise the narrower ones toward an even share: the smallest level t with sum(max(ideal, t)) = available.
      var level = available / CGFloat(ideal.count)
      for _ in 0..<ideal.count {
        let fixed = ideal.filter { $0 > level }
        guard fixed.count < ideal.count else { break }
        level = (available - fixed.reduce(0, +)) / CGFloat(ideal.count - fixed.count)
      }
      return ideal.map { max($0, level) }
    }
    // Each keeps its last fallback (what it shows at no width); the rest goes by what each needs beyond it, so one
    // provider's long row of rings never squeezes the other's counts under its neighbor.
    let least = subviews.map { $0.sizeThatFits(.init(width: 0, height: nil)).width }
    let spare = max(0, available - least.reduce(0, +))
    let more = zip(ideal, least).map { max(0, $0 - $1) }
    return zip(least, more).map { $0 + spare * $1 / max(more.reduce(0, +), 1) }
  }
}

private struct SessionQuotaProvider: View {
  /// `marks`: every mark, on two lines, never degraded (the strip moves on when it does not fit). `line`: the same
  /// on one line, the summary after the marks; `lineReady` leaves its release out. `adaptive`: two lines that fall
  /// back to counts within their width.
  enum Style { case marks, line, lineReady, adaptive }
  @Environment(\.appTheme) private var theme
  #if os(iOS)
  // The ready ring (16 pt) and the other states' symbols (12 pt) keep the approved mockup's proportion.
  @ScaledMetric(relativeTo: .caption) private var glyph = 12.0
  @ScaledMetric(relativeTo: .caption) private var ring = 16.0
  @ScaledMetric(relativeTo: .caption) private var icon = 15.0
  #else
  private let glyph = 12.0
  private let ring = 16.0
  private let icon = 14.0
  #endif
  let provider: SubscriptionProvider
  let marks: SubscriptionMarks?
  let status: String?
  let now: Date
  let style: Style

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      ProxyProviderIcon(provider: provider).frame(width: icon, height: icon)
      if style == .line || style == .lineReady {
        HStack(spacing: 7) {
          if let marks, marks.total > 0 {
            plans(marks.runs) { group in each(group) }
            summary("· " + marks.summary(now: now, compact: true, release: style == .line))
          } else {
            summary(line)
          }
        }
        .monospacedDigit()
      } else {
        VStack(alignment: .leading, spacing: 3) {
          if let marks, marks.total > 0 {
            if style == .marks {
              plans(marks.runs) { group in each(group) }
              summary(marks.summary(now: now))
            } else {
              ViewThatFits(in: .horizontal) {
                plans(marks.runs) { group in each(group) }
                plans(marks.groups) { group in counts(group) }
                plans(marks.groups) { group in ready(group) }
                states(marks)
              }
              ViewThatFits(in: .horizontal) {
                summary(marks.summary(now: now))
                summary(marks.summary(now: now, compact: true))
                summary(marks.summary(now: now, release: false))
              }
            }
          } else {
            summary(line)
          }
        }
        .monospacedDigit()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
  }

  var spoken: String { marks?.spoken(provider.title, now: now, balances: true) ?? "\(provider.title), \(line)" }

  private var line: String {
    guard let status else { return "consultando…" }
    guard status == "ok", let marks else { return status == "unconfigured" ? "sem LLM proxy" : "indisponível" }
    return marks.summary(now: now)
  }

  /// Every run or plan with its short plan label; one with no measured account shows only its `?` count.
  private func plans<Content: View>(_ groups: [SubscriptionMarks.Group],
    @ViewBuilder _ body: @escaping (SubscriptionMarks.Group) -> Content) -> some View
  {
    HStack(spacing: 7) {
      ForEach(groups) { group in
        HStack(spacing: 3) {
          Text(group.label).appFont(.footnote).foregroundStyle(theme.color(.textSecondary))
          if group.unmeasured { counts(group) } else { body(group) }
        }
        .help(group.title)
      }
    }
    .lineLimit(1)
    .fixedSize()
  }

  /// One mark per account: a ring with its balance when ready, the state's symbol otherwise; past 12 accounts a run
  /// shows its counts instead. The highlighted account gets a short dash below its mark, outside any ring.
  @ViewBuilder private func each(_ group: SubscriptionMarks.Group) -> some View {
    if group.accounts.count > 12 {
      counts(group)
    } else {
      HStack(spacing: 2) {
        ForEach(group.accounts) { account in
          Group {
            if let balance = account.balance {
              SubscriptionRingMark(balance: balance, size: ring)
            } else {
              SubscriptionMarkGlyph(kind: .init(account.mark), size: glyph)
            }
          }
          // Right under the mark, in the 1 pt between lines, so it neither covers the number nor touches the line
          // below; on the last line it falls into the margin under the strip, which keeps its height.
          .overlay(alignment: .bottom) {
            if account.pinned {
              Capsule().fill(theme.color(.textStrong)).frame(width: ring * 0.4, height: 1).offset(y: 1)
            }
          }
          .help("\(account.name) · \(group.title) · \(account.balance?.spoken ?? Self.state(account.mark))")
        }
      }
    }
  }

  private func counts(_ group: SubscriptionMarks.Group) -> some View {
    tally { group.count($0) }
  }

  /// Glyph and count of each state present.
  private func tally(_ count: @escaping (SubscriptionMarks.Kind) -> Int) -> some View {
    HStack(spacing: 4) {
      ForEach(SubscriptionMarks.Kind.allCases.filter { count($0) > 0 }, id: \.self) { kind in
        HStack(spacing: 1) {
          SubscriptionMarkGlyph(kind: kind, size: glyph)
          Text("\(count(kind))").appFont(.footnote).foregroundStyle(theme.color(.text))
        }
      }
    }
  }

  /// The narrowest strip: the provider's accounts by state, without the plans (they stay in VoiceOver, the
  /// tooltip and the details).
  private func states(_ marks: SubscriptionMarks) -> some View {
    tally { marks.count($0) }.lineLimit(1).fixedSize()
  }

  private func summary(_ text: String) -> some View {
    Text(text).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1).fixedSize()
  }

  private func ready(_ group: SubscriptionMarks.Group) -> some View {
    Text("\(Text("\(group.ready)").foregroundStyle(theme.color(group.ready > 0 ? .primary : .textSecondary)))/\(group.accounts.count)")
      .appFont(.footnote).foregroundStyle(theme.color(.textSecondary))
  }

  static func state(_ mark: SubscriptionMark) -> String {
    guard case .blocked(let until?) = mark else { return mark.title }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.dateFormat = Calendar.current.isDateInToday(until) ? "HH:mm" : "dd/MM HH:mm"
    return "parada até " + formatter.string(from: until)
  }

  #if DEBUG
  /// What the UI tests read: the strip's runs with each account's balance or state, in order
  /// (`5x:100,72,64,41,B|20x:E,E`).
  var fixture: String {
    (marks?.runs ?? []).map { group in
      group.label + ":" + group.accounts.map { account in
        if let balance = account.balance { return "\(balance.percent)" }
        switch SubscriptionMarks.Kind(account.mark) {
        case .ready: return "R"
        case .blocked: return "B"
        case .exhausted: return "E"
        case .unmeasured: return "?"
        case .attention: return "!"
        }
      }.joined(separator: ",")
    }.joined(separator: "|")
  }
  #endif
}

/// A ready subscription in the strip: a small ring whose arc is that account's own balance (the share left of the
/// window that limits it), with the number in the center and no `%`. Never an aggregate of accounts or plans.
struct SubscriptionRingMark: View {
  @Environment(\.appTheme) private var theme
  let balance: SubscriptionMarks.Balance
  let size: Double

  var body: some View {
    let stroke = size * 0.12
    ZStack {
      Circle().inset(by: stroke / 2).stroke(theme.color(.highlight), lineWidth: stroke)
      Circle().inset(by: stroke / 2).trim(from: 0, to: Double(balance.percent) / 100)
        .stroke(theme.color(.primary), lineWidth: stroke)
        .rotationEffect(.degrees(-90))
      // Condensed so "100" fits inside the ring at the same size as the other numbers.
      Text("\(balance.percent)")
        .font(.system(size: size * 0.42, weight: .bold).width(.condensed))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .foregroundStyle(theme.color(.textStrong))
        .padding(.horizontal, stroke)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// One subscription's state, readable without color: a filled dot (ready), a clock (stopped for a while), a
/// crossed circle (week exhausted), a question mark (no measurement) and a warning sign (needs login). The account
/// shown in the summary ("Mostrar no resumo") gets a ring around its mark.
struct SubscriptionMarkGlyph: View {
  @Environment(\.appTheme) private var theme
  let kind: SubscriptionMarks.Kind
  var pinned = false
  let size: Double

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(theme.color(role))
      .frame(width: size + 2, height: size + 2)
      .overlay {
        if pinned { Circle().stroke(theme.color(.textStrong), lineWidth: 1).padding(-1.5) }
      }
      .accessibilityHidden(true)
  }

  private var symbol: String {
    switch kind {
    case .ready: "circle.fill"
    case .blocked: "clock.fill"
    case .exhausted: "nosign"
    case .unmeasured: "questionmark.circle"
    case .attention: "exclamationmark.triangle.fill"
    }
  }

  private var role: ThemeRole {
    switch kind {
    case .ready: .primary
    case .blocked: .warning
    case .exhausted, .attention: .error
    case .unmeasured: .textSecondary
    }
  }
}

/// The ring of the Mac LLM proxy sidebar: the remaining share, orange while an account is ready and amber
/// otherwise.
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
