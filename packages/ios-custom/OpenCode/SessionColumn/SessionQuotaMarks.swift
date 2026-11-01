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
/// as even as possible between each one's narrowest form and what it needs when it does not, so a provider with
/// longer plan names keeps its marks while the other never overflows. Each provider then fits its own content to
/// that width.
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
    // As even as the row allows, never below a provider's last fallback (what it shows at no width) nor above what
    // it needs: one provider's long row of rings never squeezes the other's counts under its neighbor, and both
    // keep room for when their next accounts are back.
    let least = subviews.map { $0.sizeThatFits(.init(width: 0, height: nil)).width }
    func widths(_ level: CGFloat) -> [CGFloat] { zip(least, ideal).map { min(max($0, $1), max($0, level)) } }
    let level = (0..<30).reduce((low: CGFloat(0), high: ideal.max() ?? 0)) { range, _ in
      let middle = (range.low + range.high) / 2
      return widths(middle).reduce(0, +) > available ? (range.low, middle) : (middle, range.high)
    }.low
    return widths(level)
  }
}

private struct SessionQuotaProvider: View {
  /// `marks`: every mark, on two lines, never degraded (the strip moves on when it does not fit). `line`: the same
  /// on one line, the summary after the marks. Both leave the release out: each stopped mark shows its own wait.
  /// `adaptive`: two lines that fall back to counts within their width, which then say when the next ones are back.
  enum Style { case marks, line, adaptive }
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
      if style == .line {
        HStack(spacing: 7) {
          if let marks, marks.total > 0 {
            plans(marks.runs) { group in each(group) }
            summary("· " + marks.summary(now: now, release: false))
          } else {
            summary(line)
          }
        }
        .monospacedDigit()
      } else {
        Group {
          if let marks, marks.total > 0 {
            if style == .marks {
              lines(plans(marks.runs) { group in each(group) }, marks.summary(now: now, release: false))
            } else {
              // The marks first, without the release; then counts, whose summary says when the next ones are back
              // (`+1 em 35m`, then `+1 35m`): plans give way to keep it before it goes.
              ViewThatFits(in: .horizontal) {
                lines(plans(marks.runs) { group in each(group) }, marks.summary(now: now, release: false))
                ForEach(Self.fallbacks, id: \.self) { fallback in
                  lines(top(fallback.top, marks), marks.summary(now: now, next: fallback.next, compact: fallback.compact))
                }
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

  /// The counts fallbacks in order: by state per plan, the ready share per plan, the provider's states; each with
  /// the next return, then its compact form, then without it.
  private struct Fallback: Hashable { let top: Int; let next: Bool; let compact: Bool }
  private static let fallbacks = [(true, false), (true, true), (false, false)].flatMap { next, compact in
    (0..<3).map { Fallback(top: $0, next: next, compact: compact) }
  }

  @ViewBuilder private func top(_ kind: Int, _ marks: SubscriptionMarks) -> some View {
    switch kind {
    case 0: plans(marks.groups) { group in counts(group) }
    case 1: plans(marks.groups) { group in ready(group) }
    default: states(marks)
    }
  }

  private func lines<Top: View>(_ top: Top, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      top
      summary(text)
    }
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
            } else if let wait = account.wait {
              SubscriptionWaitMark(kind: .init(account.mark), text: wait.short(now: now), size: glyph)
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
          .help("\(account.name) · \(group.title) · \(state(account))")
        }
      }
    }
  }

  private func counts(_ group: SubscriptionMarks.Group) -> some View {
    tally(group.accounts)
  }

  /// Glyph and count of each state present; exhausted weeks show the renewal arrow when every one has a known
  /// renewal, the crossed circle otherwise.
  private func tally(_ accounts: [SubscriptionMarks.Account]) -> some View {
    let exhausted = accounts.filter { SubscriptionMarks.Kind($0.mark) == .exhausted }
    return HStack(spacing: 4) {
      ForEach(SubscriptionMarks.Kind.allCases.filter { kind in accounts.contains { SubscriptionMarks.Kind($0.mark) == kind } }, id: \.self) { kind in
        HStack(spacing: 1) {
          SubscriptionMarkGlyph(kind: kind, renewing: kind == .exhausted && exhausted.allSatisfy { $0.wait != nil }, size: glyph)
          Text("\(accounts.filter { SubscriptionMarks.Kind($0.mark) == kind }.count)").appFont(.footnote)
            .foregroundStyle(theme.color(.text))
        }
      }
    }
  }

  /// The narrowest strip: the provider's accounts by state, without the plans (they stay in VoiceOver, the
  /// tooltip and the details).
  private func states(_ marks: SubscriptionMarks) -> some View {
    tally(marks.groups.flatMap(\.accounts)).lineLimit(1).fixedSize()
  }

  private func summary(_ text: String) -> some View {
    Text(text).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1).fixedSize()
  }

  private func ready(_ group: SubscriptionMarks.Group) -> some View {
    Text("\(Text("\(group.ready)").foregroundStyle(theme.color(group.ready > 0 ? .primary : .textSecondary)))/\(group.accounts.count)")
      .appFont(.footnote).foregroundStyle(theme.color(.textSecondary))
  }

  /// The tooltip's state: the balance and its window, the wait with its time and cause, or the state alone.
  private func state(_ account: SubscriptionMarks.Account) -> String {
    if let balance = account.balance { return balance.spoken }
    if let wait = account.wait { return account.mark.title + ", " + wait.spoken(now: now) }
    // The proxy's wait over windows read too long ago: its end does not say the account is back.
    guard case .blocked(let until?) = account.mark else { return account.mark.title }
    return "parada até " + SubscriptionFormat.moment(until, now: now) + " (medição antiga, volta não confirmada)"
  }

  #if DEBUG
  /// What the UI tests read: the strip's runs with each account's balance, state and wait, in order, `^` after the
  /// highlighted one (`5x:100,72^,64,41,B2h|20x:E3d,E3d`).
  var fixture: String {
    (marks?.runs ?? []).map { group in
      group.label + ":" + group.accounts.map { account in
        let mark: String = {
          if let balance = account.balance { return "\(balance.percent)" }
          switch SubscriptionMarks.Kind(account.mark) {
          case .ready: return "R"
          case .blocked: return "B"
          case .exhausted: return "E"
          case .unmeasured: return "?"
          case .attention: return "!"
          }
        }()
        return mark + (account.wait?.short(now: now) ?? "") + (account.pinned ? "^" : "")
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

/// A stopped or exhausted subscription whose return the data gives: the state's symbol (a clock for a wait, the
/// renewal arrow for an exhausted week) and how long is left, rounded up (`35m`, `2h`, `2d`). An estimate: the
/// tooltip, VoiceOver and the details carry the time and its cause.
struct SubscriptionWaitMark: View {
  @Environment(\.appTheme) private var theme
  let kind: SubscriptionMarks.Kind
  let text: String
  let size: Double

  var body: some View {
    HStack(spacing: 1.5) {
      SubscriptionMarkGlyph(kind: kind, renewing: kind == .exhausted, size: size)
      Text(text)
        .font(.system(size: size * 0.84, weight: .bold).width(.condensed))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(theme.color(kind == .exhausted ? .error : .warning))
    }
    // Apart from the next mark, so a clock that follows never reads as part of this time.
    .padding(.trailing, 2)
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
  /// An exhausted week with a known renewal: the renewal arrow instead of the crossed circle.
  var renewing = false
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
    case .exhausted: renewing ? "arrow.clockwise" : "nosign"
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
