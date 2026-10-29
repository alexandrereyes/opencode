import OpenCodeKit
import SwiftUI

/// Painel (`app-1-painel.png`): ring and counts with the age of the state, pending requests first, then the
/// sessions; the microphone starts voice. Refreshes on coming to the front, every 10 s while visible and on pull;
/// in the background the app refresh keeps the cache current (`BackgroundRefresh`).
struct DashboardView: View {
  @Environment(\.scenePhase) private var scenePhase
  let model: WatchModel
  let voice: VoiceCall
  @State private var reply: ReplyRoute?
  @State private var showVoice = false

  var body: some View {
    NavigationStack {
      content
        .navigationDestination(item: $reply) { route in ReplyView(model: model, route: route) }
        .navigationDestination(isPresented: $showVoice) { VoiceView(call: voice, pairing: model.pairing) }
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Text("OpenCode").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.watch(.primary))
          }
        }
    }
    .task(id: scenePhase) {
      // While visible: refresh now and every 10 s. In the background, `BackgroundRefresh` takes over.
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        await model.refreshNow()
        try? await Task.sleep(for: .seconds(10))
      }
    }
    .onChange(of: voice.phase) { _, phase in
      if phase != .idle { showVoice = true }
    }
  }

  @ViewBuilder private var content: some View {
    if model.pairing == nil {
      Message(title: model.connection == .unauthorized ? "Pareamento expirado" : "Sem pareamento",
        text: "Abra o OpenCode no iPhone para parear")
    } else if model.connection == .loading && model.entry == nil {
      ProgressView().tint(Color.watch(.primary))
    } else {
      ScrollViewReader { proxy in
      List {
        header.listRowBackground(Color.clear)
        if model.connection == .unreachable {
          offline.listRowBackground(Color.clear)
        }
        ForEach(model.state?.dashboardRows ?? []) { row in
          Group {
            switch row {
            case .attention(let item):
              Button { reply = ReplyRoute(attention: item) } label: { AttentionRow(item: item) }
                .listRowBackground(Card(tint: item.kind == .permission ? .warning : .accent, outlined: true))
            case .session(let session):
              // No navigation for sessions in v1: no chevron, not a button.
              SessionRow(row: session, unread: model.state?.counts.unread != nil).listRowBackground(Card(tint: nil, outlined: false))
            }
          }.id(row.id)
        }
        if model.state?.dashboardRows.isEmpty ?? true {
          Text("Nenhuma sessão ativa").font(.footnote).foregroundStyle(Color.watch(.textSecondary))
            .listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
      .refreshable { await model.refreshNow() }
      // The microphone gets its own bottom inset: rows end above it and never pass under the button.
      .safeAreaInset(edge: .bottom, spacing: 0) { microphone }
      .task {
        guard WatchFixture.launch?.screen == .dashboardEnd, let last = model.state?.dashboardRows.last else { return }
        try? await Task.sleep(for: .milliseconds(300))
        proxy.scrollTo(last.id, anchor: .bottom)
      }
      }
    }
  }

  /// A short opaque band reserved below the rows (30 pt); the 44 pt button extends into the rounded corner
  /// beneath it, where the band continues, so no row ever passes under the button.
  private var microphone: some View {
    Color.black
      .frame(height: 30)
      .overlay(alignment: .topTrailing) {
        Button { showVoice = true } label: {
          Image(systemName: "mic.fill").font(.system(size: 19)).foregroundStyle(Color.watch(.primary))
        }
        .buttonStyle(.glass).buttonBorderShape(.circle).frame(width: 44, height: 44)
        .padding(.trailing, 6)
        .accessibilityLabel("Falar com a Sessão mestra")
        .accessibilityIdentifier("watch-voice")
      }
      .background(Color.black.ignoresSafeArea(edges: .bottom))
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        WatchRingView(state: model.state, lineWidth: 6, numberSize: 26).frame(width: 62, height: 62)
        VStack(alignment: .leading, spacing: 1) {
          Text(model.state?.activeLabel ?? "0 ativas").font(.system(size: 19, weight: .semibold))
            .foregroundStyle(Color.watch(.textStrong))
          if let attention = model.state?.attentionLabel {
            Text(attention).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.watch(.accent))
              .lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      if let fetched = model.entry?.fetched {
        // Below the ring, across the width; re-rendered when `agora` turns into the relative age.
        TimelineView(.periodic(from: fetched, by: WatchAge.fresh)) { context in
          HStack(spacing: 3) {
            Text("Atualizado")
            WatchAgeText(fetched: fetched, now: context.date)
          }
          .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.watch(.textSecondary)).lineLimit(1)
        }
        .accessibilityIdentifier("watch-age")
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  /// The header already says how old the state is.
  private var offline: some View {
    Label("Mac indisponível", systemImage: "wifi.slash").font(.system(size: 14, weight: .semibold))
      .foregroundStyle(Color.watch(.warning))
  }
}

struct ReplyRoute: Hashable {
  let attention: AgentsState.Attention
}

private struct Card: View {
  let tint: ThemeRole?
  let outlined: Bool
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    shape.fill(tint.map { Color.watch($0).opacity(0.22) } ?? Color.watch(.surfaceRaised).opacity(0.9))
      .overlay { if outlined, let tint { shape.strokeBorder(Color.watch(tint).opacity(0.7), lineWidth: 1) } }
      .padding(.vertical, 2)
  }
}

private struct AttentionRow: View {
  let item: AgentsState.Attention
  var body: some View {
    let role: ThemeRole = item.kind == .permission ? .warning : .accent
    HStack(spacing: 10) {
      Image(systemName: item.kind == .permission ? "hand.raised.fill" : "questionmark")
        .font(.system(size: 16, weight: .bold)).foregroundStyle(Color.watch(role))
        .frame(width: 32, height: 32).background(Circle().fill(Color.watch(role).opacity(0.25)))
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.watch(.textStrong))
          .lineLimit(1).minimumScaleFactor(0.8)
        Text("\(item.project) · \(Text(.currentDate, format: AgentsText.ago(since: item.asked)))")
          .font(.system(size: 12)).foregroundStyle(Color.watch(.textSecondary)).lineLimit(1)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.watch(.textSecondary))
    }
    .padding(.vertical, 6)
    .accessibilityIdentifier("watch-attention-\(item.sessionID)")
  }
}

private struct SessionRow: View {
  let row: AgentsState.Row
  /// The backend sends `counts.unread`, so `idle` rows are unread sessions.
  let unread: Bool
  var body: some View {
    let role = row.statusRole(unread: unread)
    HStack(spacing: 10) {
      ZStack {
        Circle().fill(Color.watch(.surface))
        if let symbol = row.status.watchSymbol {
          Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.watch(role))
        } else {
          Circle().fill(Color.watch(role)).frame(width: 12, height: 12)
        }
      }.frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.watch(.textStrong))
          .lineLimit(1).minimumScaleFactor(0.8)
        Text(row.statusLabel(unread: unread)).font(.system(size: 12)).foregroundStyle(Color.watch(role)).lineLimit(1)
          .monospacedDigit()
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
  }
}

struct Message: View {
  let title: String
  let text: String
  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        WatchMascot().frame(width: 48)
        Text(title).font(.headline).foregroundStyle(Color.watch(.textStrong))
        Text(text).font(.footnote).multilineTextAlignment(.center).foregroundStyle(Color.watch(.textSecondary))
      }.padding(.top, 8)
    }
  }
}
