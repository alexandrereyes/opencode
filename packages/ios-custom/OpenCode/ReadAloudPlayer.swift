import AVFoundation
import MediaPlayer
import Observation
import OpenCodeKit

extension Notification.Name {
  /// The microphone is about to be used (voice mode, dictation); spoken playback pauses for it.
  static let audioCaptureWillStart = Notification.Name("br.com.alexandrem.opencode.audio-capture-will-start")
}

/// Reads a Markdown document aloud with audio the server generates piece by piece (`custom.speech`).
/// Only pieces near the playhead are generated, so seeking or stopping early never pays for the rest.
@MainActor @Observable final class ReadAloudPlayer {
  enum Phase: Equatable { case idle, loading, playing, paused, failed(String) }
  static let rates: [Float] = [1, 1.5, 2]
  static let rateKey = "OpenCodeReadAloudRate"
  /// The server's estimate until `custom.speech/info` answers.
  static let defaultCharactersPerSecond = 12.0

  let title: String
  let pieces: [ReadAloud.Piece]
  private(set) var timeline: ReadAloud.Timeline
  private(set) var phase: Phase = .idle
  /// Seconds into the whole document.
  private(set) var position: Double = 0
  private(set) var rate: Float
  /// Estimated cost of a long document, while the app asks before generating it.
  var confirmation: (seconds: Double, usd: Double)?

  @ObservationIgnored private let client: OpenCodeClient
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var info: SpeechInfo?
  @ObservationIgnored private var confirmed = false
  @ObservationIgnored private var audio: [Int: Data] = [:]
  @ObservationIgnored private var requests: [Int: Task<Data, any Error>] = [:]
  @ObservationIgnored private var player: AVAudioPlayer?
  @ObservationIgnored private var current = 0
  @ObservationIgnored private var starting: Task<Void, Never>?
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var session = false
  @ObservationIgnored private var interrupted = false
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []
  @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
  @ObservationIgnored private let delegate = Delegate()

  init(title: String, pieces: [ReadAloud.Piece], client: OpenCodeClient, defaults: UserDefaults = .standard) {
    self.title = title
    self.pieces = pieces
    self.client = client
    self.defaults = defaults
    timeline = ReadAloud.Timeline(pieces: pieces, charactersPerSecond: Self.defaultCharactersPerSecond)
    let saved = defaults.float(forKey: Self.rateKey)
    rate = Self.rates.contains(saved) ? saved : 1
    delegate.finished = { [weak self] player in self?.finished(player) }
    delegate.failed = { [weak self] player in
      guard let self, player === self.player else { return }
      self.fail("Não foi possível tocar o áudio.")
    }
  }

  var total: Double { timeline.total }
  var busy: Bool { phase == .playing || phase == .loading }

  func toggle() { busy ? pause() : play() }

  func play() {
    guard !pieces.isEmpty else { return }
    if position >= total - 0.25 { position = 0 }
    let target = timeline.locate(position)
    if let player, target.piece == current, phase == .paused {
      player.currentTime = min(player.duration, max(0, position - timeline.start(current)))
      resume(player)
      return
    }
    start(target.piece, at: target.fraction)
  }

  func pause() {
    starting?.cancel(); starting = nil
    ticker?.cancel(); ticker = nil
    if let player {
      player.pause()
      position = timeline.time(piece: current, offset: player.currentTime)
    }
    phase = .paused
    publish()
  }

  /// Jumps anywhere in the document; a piece without audio yet is generated and starts at the same proportion.
  func seek(to time: Double) {
    let time = min(max(0, time), total)
    let target = timeline.locate(time)
    position = time
    if let player, target.piece == current {
      player.currentTime = target.fraction * player.duration
      publish()
      return
    }
    if busy { start(target.piece, at: target.fraction); return }
    player = nil
    publish()
  }

  func skip(_ seconds: Double) { seek(to: position + seconds) }

  func cycleRate() {
    rate = Self.rates[((Self.rates.firstIndex(of: rate) ?? 0) + 1) % Self.rates.count]
    defaults.set(rate, forKey: Self.rateKey)
    player?.rate = rate
    publish()
  }

  func confirm() {
    confirmed = true
    confirmation = nil
    play()
  }

  func retry() { play() }

  /// Closing or leaving the file ends playback and releases the audio session and lock screen controls.
  func stop() {
    starting?.cancel(); starting = nil
    ticker?.cancel(); ticker = nil
    requests.values.forEach { $0.cancel() }
    requests = [:]
    player?.stop(); player = nil
    phase = .idle
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
    commands.forEach { $0.0.removeTarget($0.1) }
    commands = []
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    if session { DictationAudioSession.deactivate(); session = false }
  }

  private func start(_ piece: Int, at fraction: Double) {
    starting?.cancel()
    ticker?.cancel(); ticker = nil
    player?.stop(); player = nil
    current = piece
    position = timeline.time(piece: piece, offset: fraction * timeline.duration(piece))
    phase = .loading
    starting = Task { [weak self] in
      guard let self else { return }
      do {
        guard try await prepared() else { return }
        let data = try await load(piece)
        try Task.checkCancellation()
        let player = try AVAudioPlayer(data: data)
        player.enableRate = true
        player.rate = rate
        player.delegate = delegate
        player.prepareToPlay()
        timeline.durations[piece] = player.duration
        player.currentTime = fraction * player.duration
        self.player = player
        // Pieces behind the playhead are dropped; the server cache serves them again on a seek back.
        audio = audio.filter { $0.key >= piece - 1 }
        resume(player)
        prefetch(after: piece)
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        fail(Self.message(error))
      }
    }
  }

  /// Asks the server for its estimate once, then pauses at the cost prompt for a very long document.
  private func prepared() async throws -> Bool {
    if info == nil {
      let info = try await client.speechInfo()
      self.info = info
      let durations = timeline.durations
      timeline = ReadAloud.Timeline(pieces: pieces, charactersPerSecond: info.charactersPerSecond)
      timeline.durations = durations
    }
    try Task.checkCancellation()
    guard !confirmed, total > ReadAloud.confirmationSeconds, let info else { return true }
    phase = .paused
    confirmation = (total, ReadAloud.cost(seconds: total, usdPerSecond: info.usdPerSecond))
    return false
  }

  private func resume(_ player: AVAudioPlayer) {
    phase = .loading
    observe()
    let queued = QueuedAudio(value: player)
    starting = Task { [weak self] in
      do {
        try await DictationAudioSession.activate(.playback, mode: .spokenAudio) {
          guard queued.value.play() else { throw ClientError.operation("play") }
        }
        guard let self else { return }
        session = true
        guard !Task.isCancelled, player === self.player else { player.pause(); return }
        phase = .playing
        tick()
        publish()
      } catch {
        guard let self, !Task.isCancelled else { return }
        fail("Não foi possível ativar o áudio.")
      }
    }
  }

  private func load(_ piece: Int) async throws -> Data {
    if let data = audio[piece] { return data }
    let request = requests[piece] ?? Task { [client, text = pieces[piece].text] in try await client.synthesizeSpeech(text) }
    requests[piece] = request
    do {
      let data = try await request.value
      audio[piece] = data
      requests[piece] = nil
      return data
    } catch {
      requests[piece] = nil
      throw error
    }
  }

  /// The next two pieces generate while this one plays, each about three times longer than its generation.
  private func prefetch(after piece: Int) {
    for next in (piece + 1)..<min(pieces.count, piece + 3) where audio[next] == nil && requests[next] == nil {
      Task { [weak self] in _ = try? await self?.load(next) }
    }
  }

  private func finished(_ player: AVAudioPlayer) {
    guard player === self.player else { return }
    ticker?.cancel(); ticker = nil
    timeline.durations[current] = player.duration
    if current + 1 < pieces.count {
      start(current + 1, at: 0)
      return
    }
    self.player = nil
    phase = .paused
    position = total
    publish()
  }

  private func fail(_ message: String) {
    ticker?.cancel(); ticker = nil
    player?.pause()
    phase = .failed(message)
    publish()
  }

  private func tick() {
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let player = self.player else { return }
        position = timeline.time(piece: current, offset: player.currentTime)
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  /// Interruptions (calls, Siri), unplugged headphones and the microphone pause reading; an interruption that ends
  /// with the system's resume hint continues it.
  private func observe() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { note in
      let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
      guard context?.source == .system else { return }
      MainActor.assumeIsolated { [weak self] in
        guard let self, busy else { return }
        interrupted = true
        pause()
      }
    })
    observers.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { note in
      let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
      MainActor.assumeIsolated { [weak self] in
        guard let self, interrupted else { return }
        interrupted = false
        if context?.recommendation == .shouldResume { play() }
      }
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
      MainActor.assumeIsolated { [weak self] in
        guard let self, reason == .oldDeviceUnavailable, busy else { return }
        pause()
      }
    })
    observers.append(center.addObserver(forName: .audioCaptureWillStart, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { [weak self] in
        guard let self, busy else { return }
        pause()
      }
    })
    remoteCommands()
  }

  private func remoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (ReadAloudPlayer, MPRemoteCommandEvent) -> Void) {
      command.isEnabled = true
      let target = command.addTarget { [weak self] event in
        MainActor.assumeIsolated {
          guard let self else { return .noActionableNowPlayingItem }
          action(self, event)
          return .success
        }
      }
      commands.append((command, target))
    }
    add(center.playCommand) { player, _ in player.play() }
    add(center.pauseCommand) { player, _ in player.pause() }
    add(center.togglePlayPauseCommand) { player, _ in player.toggle() }
    center.skipForwardCommand.preferredIntervals = [15]
    center.skipBackwardCommand.preferredIntervals = [15]
    add(center.skipForwardCommand) { player, _ in player.skip(15) }
    add(center.skipBackwardCommand) { player, _ in player.skip(-15) }
    add(center.changePlaybackPositionCommand) { player, event in
      if let event = event as? MPChangePlaybackPositionCommandEvent { player.seek(to: event.positionTime) }
    }
  }

  private func publish() {
    guard session || !commands.isEmpty else { return }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: "OpenCode",
      MPMediaItemPropertyPlaybackDuration: total,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? Double(rate) : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
    ]
    MPNowPlayingInfoCenter.default().playbackState = phase == .playing ? .playing : .paused
  }

  static func message(_ error: any Error) -> String {
    switch error {
    case ClientError.rpc("unavailable"): "Leitura indisponível: o servidor não tem uma chave do Vercel AI Gateway."
    case ClientError.rpc("synthesis_failed"): "O servidor não conseguiu gerar este trecho."
    case ClientError.rpc(let type) where type.contains("not_found"): "Atualize o servidor para ouvir documentos."
    case is URLError: "Sem conexão com o servidor."
    default: "Não foi possível gerar o áudio."
    }
  }

  private final class Delegate: NSObject, AVAudioPlayerDelegate {
    @MainActor var finished: ((AVAudioPlayer) -> Void)?
    @MainActor var failed: ((AVAudioPlayer) -> Void)?
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
      let queued = QueuedAudio(value: player)
      Task { @MainActor in flag ? self.finished?(queued.value) : self.failed?(queued.value) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
      let queued = QueuedAudio(value: player)
      Task { @MainActor in self.failed?(queued.value) }
    }
  }
}
