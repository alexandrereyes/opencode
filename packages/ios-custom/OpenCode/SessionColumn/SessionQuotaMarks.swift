import OpenCodeKit
import SwiftUI

/// The Sessões quota strip, shared by the iPhone and the Mac: for each LLM proxy provider, in `providers` order, its
/// small icon, every enabled subscription as one mark grouped by the plan the proxy reports, and how many are ready
/// now (`SubscriptionMarks`). It replaces the rings, which averaged one plan's weekly percent, within their row
/// (38 pt): the providers side by side on two lines; where the marks do not fit side by side, one line each (then
/// without the release time); only then counts by state per plan, the ready share per plan, and the provider's
/// counts by state. A provider opens its subscription details.
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
        VStack(alignment: .leading, spacing: 3) { providers(.line) }
        VStack(alignment: .leading, spacing: 3) { providers(.lineReady) }
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
/// in proportion to what each needs when it does not, so a provider with longer plan names keeps its marks
/// while the other has room to spare. Each provider then fits its own content to that width.
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
    return ideal.map { available * $0 / max(total, 1) }
  }
}

private struct SessionQuotaProvider: View {
  /// `marks`: every mark, on two lines, never degraded (the strip moves on when it does not fit). `line`: the same
  /// on one line, the summary after the marks; `lineReady` leaves its release out. `adaptive`: two lines that fall
  /// back to counts within their width.
  enum Style { case marks, line, lineReady, adaptive }
  @Environment(\.appTheme) private var theme
  #if os(iOS)
  @ScaledMetric(relativeTo: .caption) private var glyph = 10.0
  @ScaledMetric(relativeTo: .caption) private var icon = 15.0
  #else
  private let glyph = 10.0
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
            plans(marks) { group in each(group) }
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
              plans(marks) { group in each(group) }
              summary(marks.summary(now: now))
            } else {
              ViewThatFits(in: .horizontal) {
                plans(marks) { group in each(group) }
                plans(marks) { group in counts(group) }
                plans(marks) { group in ready(group) }
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

  var spoken: String { marks?.spoken(provider.title, now: now) ?? "\(provider.title), \(line)" }

  private var line: String {
    guard let status else { return "consultando…" }
    guard status == "ok", let marks else { return status == "unconfigured" ? "sem LLM proxy" : "indisponível" }
    return marks.summary(now: now)
  }

  /// Every group with its short plan label; a group with no measured account shows only its `?` count.
  private func plans<Content: View>(_ marks: SubscriptionMarks,
    @ViewBuilder _ body: @escaping (SubscriptionMarks.Group) -> Content) -> some View
  {
    HStack(spacing: 7) {
      ForEach(marks.groups) { group in
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

  /// One mark per account; past 12 accounts a plan shows its counts instead.
  @ViewBuilder private func each(_ group: SubscriptionMarks.Group) -> some View {
    if group.accounts.count > 12 {
      counts(group)
    } else {
      HStack(spacing: 1.5) {
        ForEach(group.accounts) { account in
          SubscriptionMarkGlyph(kind: .init(account.mark), pinned: account.pinned, size: glyph)
            .help("\(account.name) · \(group.title) · \(Self.state(account.mark))")
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
  /// What the UI tests read: every plan with each account's mark, in order (`5x:RRRRB|20x:EE`).
  var fixture: String {
    (marks?.groups ?? []).map { group in
      group.label + ":" + group.accounts.map { account in
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
