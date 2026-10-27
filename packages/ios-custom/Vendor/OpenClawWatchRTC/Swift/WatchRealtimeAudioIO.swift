// Copiado de OpenClaw (MIT, Copyright (c) 2026 OpenClaw Foundation), commit e5cc2d9,
// apps/ios/WatchApp/Sources/WatchRealtimeAudioIO.swift. Ver ../Licenses/OpenClaw.txt.
import AVFAudio
import Foundation
import Synchronization

/// Graph mutations, conversion, codecs and playback have one queue owner. The tap only
/// copies its borrowed buffer; its bounded handoff and cancellation are mutex protected.
final class WatchRealtimeAudioIO: @unchecked Sendable {
    private struct AudioGate {
        var stopped = false
        var muted = false
        var pending = 0
        var pendingPlayback = 0
    }

    private struct CapturedAudio: Sendable {
        let format: AudioStreamBasicDescription
        let frames: AVAudioFrameCount
        let buffers: [Data]
    }

    private static let lease = Mutex<UUID?>(nil)
    private let id = UUID()
    private let queue = DispatchQueue(label: "ai.openclaw.watch.realtime.audio", qos: .userInitiated)
    private let gate = Mutex(AudioGate())
    private var onPacket: (@Sendable (Data, UInt64) -> Void)?
    private let onLevel: @Sendable (Float) -> Void
    private var onFailure: (@Sendable (String) -> Void)?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var codec: WatchOpusCodec?
    private var resampler: AVAudioConverter?
    private var frame: AVAudioPCMBuffer?
    private var frameOffset = 0
    private var timestamp: UInt64 = 0
    private var scheduledFrames: UInt32 = 0
    private var playbackGeneration: UInt64 = 0
    private var observations: [NSObjectProtocol] = []
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []
    private var activating = false
    private var ownsLease = false
    private var running = false
    private var hasTap = false

    // OpenCode (alterações locais, não estão no OpenClaw): nível de saída, plano de ativação
    // e sinal de áudio fluindo de verdade.
    enum Plan: Sendable {
        /// playAndRecord/voiceChat com ativação própria (só o simulador, que não tem CallKit).
        case duplex
        /// O CallKit já ativou a sessão (provider didActivate); não ativar nem desativar.
        case external
    }

    struct Flow: Sendable {
        var captured = 0
        var played = 0
        var capture = true
        var categoryNote = ""
    }

    private let onOutputLevel: @Sendable (Float) -> Void
    private var outputPackets = 0
    private let plan: Plan
    private var capture = true
    let flow = Mutex(Flow())

    init(plan: Plan = .duplex, onLevel: @escaping @Sendable (Float) -> Void,
        onOutputLevel: @escaping @Sendable (Float) -> Void = { _ in })
    {
        self.plan = plan
        self.onLevel = onLevel
        self.onOutputLevel = onOutputLevel
    }

    deinit {
        self.observations.forEach { NotificationCenter.default.removeObserver($0) }
        if self.hasTap { self.engine.inputNode.removeTap(onBus: 0) }
        self.player.stop()
        self.engine.stop()
        if self.ownsLease {
            #if os(watchOS)
            if case .external = self.plan {} else {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            #endif
            Self.lease.withLock { if $0 == self.id { $0 = nil } }
        }
    }

    func start(
        onPacket: @escaping @Sendable (Data, UInt64) -> Void,
        onFailure: @escaping @Sendable (String) -> Void) async throws
    {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async { self.begin(continuation, onPacket: onPacket, onFailure: onFailure) }
            }
        } onCancel: { self.cancel() }
    }

    func setMuted(_ muted: Bool) {
        self.gate.withLock { $0.muted = muted }
        self.queue.async {
            if self.running, self.capture { self.engine.inputNode.isVoiceProcessingInputMuted = muted }
        }
    }

    func play(_ packet: Data) {
        // Bound work before enqueueing, not only PCM after decoding: route changes
        // or a slow converter must not accumulate an unbounded packet backlog.
        guard self.gate.withLock({ state in
            guard !state.stopped, state.pendingPlayback < 12 else { return false }
            state.pendingPlayback += 1
            return true
        }) else { return }
        self.queue.async { [self] in
            defer { self.gate.withLock { $0.pendingPlayback -= 1 } }
            guard self.running, !self.gate.withLock({ $0.stopped }), let codec = self.codec else { return }
            do {
                let pcm = try codec.decode(packet)
                guard pcm.frameLength > 0 else { return }
                self.outputPackets += 1
                if self.outputPackets % 5 == 0 {
                    var energy: Float = 0
                    for sample in 0..<Int(pcm.frameLength) {
                        let value = pcm.floatChannelData![0][sample]
                        energy += value * value
                    }
                    self.onOutputLevel(min(1, sqrt(energy / Float(pcm.frameLength)) * 4))
                }
                // Cancellation may arrive during decode; fence the final playback admission.
                self.gate.withLock { state in
                    guard !state.stopped else { return }
                    // Bound queued speech to 240 ms at the negotiated 48 kHz.
                    if self.scheduledFrames + pcm.frameLength > 11520 { self.clearPlayback() }
                    let generation = self.playbackGeneration
                    let frames = pcm.frameLength
                    self.scheduledFrames += frames
                    self.player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            guard self.playbackGeneration == generation else { return }
                            self.scheduledFrames -= frames
                        }
                    }
                    if !self.player.isPlaying { self.player.play() }
                }
            } catch { self.fail(error.localizedDescription) }
        }
    }

    func cancel() {
        self.gate.withLock { $0.stopped = true }
        self.queue.async { self.finishStopIfPossible() }
    }

    func stop() async {
        self.gate.withLock { $0.stopped = true }
        await withCheckedContinuation { continuation in
            self.queue.async {
                self.stopContinuations.append(continuation)
                self.finishStopIfPossible()
            }
        }
    }

    private func begin(
        _ continuation: CheckedContinuation<Void, Error>,
        onPacket: @escaping @Sendable (Data, UInt64) -> Void,
        onFailure: @escaping @Sendable (String) -> Void)
    {
        guard !self.gate.withLock({ $0.stopped }) else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard !self.ownsLease, Self.lease.withLock({ owner in
            guard owner == nil else { return false }
            owner = self.id
            return true
        }) else {
            continuation
                .resume(throwing: WatchRealtimeMediaError
                    .unavailable(String(localized: "Another voice session is still stopping.")))
            return
        }
        self.ownsLease = true
        self.onPacket = onPacket
        self.onFailure = onFailure
        self.startContinuation = continuation
        do {
            self.codec = try WatchOpusCodec()
            self.engine.attach(self.player)
            #if os(watchOS)
            let session = AVAudioSession.sharedInstance()
            switch self.plan {
            case .external:
                // CallKit já configurou e ativou a sessão; só montar o grafo.
                self.flow.withLock { $0.categoryNote = "callkit:\(session.category.rawValue)/\(session.mode.rawValue)" }
                self.finishStart()
                return
            case .duplex:
                // Long-form routing is playback-only. Duplex voice uses the default policy;
                // async activation must finish before any low-level Watch networking begins.
                try session.setCategory(.playAndRecord, mode: .voiceChat, policy: .default, options: [])
                self.flow.withLock { $0.categoryNote = "playAndRecord/voiceChat/default" }
            }
            self.activating = true
            session.activate(options: []) { activated, error in
                self.queue.async {
                    self.activating = false
                    if self.gate.withLock({ $0.stopped }) { self.finishStopIfPossible()
                        return
                    }
                    guard activated
                    else {
                        self
                            .fail(error?
                                .localizedDescription ?? String(localized: "Voice audio could not be activated."))
                        return
                    }
                    self.finishStart()
                }
            }
            #else
            self.finishStart()
            #endif
        } catch { self.fail(error.localizedDescription) }
    }

    private func finishStart() {
        do {
            #if targetEnvironment(simulator)
            // OpenCode: o simulador pode não ter microfone; segue só com saída para exercitar a rede.
            do {
                try self.configureGraph()
            } catch where self.capture {
                self.capture = false
                self.flow.withLock { $0.capture = false
                    $0.categoryNote += " (simulador sem microfone)" }
                try self.configureGraph()
            }
            #else
            try self.configureGraph()
            #endif
            self.observeAudioChanges()
            let continuation = self.startContinuation
            self.startContinuation = nil
            continuation?.resume()
        } catch { self.fail(error.localizedDescription) }
    }

    private func configureGraph() throws {
        self.stopGraph()
        guard let codec = self.codec
        else { throw WatchRealtimeMediaError.unavailable(String(localized: "Voice audio is not ready.")) }
        guard self.capture else {
            // C sem microfone: só saída.
            self.engine.disconnectNodeOutput(self.player)
            self.engine.connect(self.player, to: self.engine.mainMixerNode, format: codec.pcmFormat)
            self.engine.prepare()
            try self.engine.start()
            self.running = true
            self.primePlayback(codec)
            return
        }
        let input = self.engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let resampler = AVAudioConverter(from: format, to: codec.pcmFormat),
              let frame = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: WatchOpusCodec.frameCount)
        else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "The current audio route has no microphone."))
        }
        resampler.primeMethod = .none
        self.resampler = resampler
        self.frame = frame
        self.frameOffset = 0
        self.engine.disconnectNodeOutput(self.player)
        self.engine.connect(self.player, to: self.engine.mainMixerNode, format: codec.pcmFormat)
        input.isVoiceProcessingInputMuted = self.gate.withLock { $0.muted }
        // AVAudioNode supports 100–400 ms tap buffers, independent of the 20 ms wire frames.
        input
            .installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(format.sampleRate / 10),
                format: format)
            { [weak self] buffer, _ in
                self?.capture(buffer)
            }
        self.hasTap = true
        self.engine.prepare()
        try self.engine.start()
        self.running = true
        self.primePlayback(codec)
    }

    /// OpenCode: toca 300 ms de silêncio para a saída estar renderizando antes do UDP.
    private func primePlayback(_ codec: WatchOpusCodec) {
        guard let silence = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: 14400) else { return }
        silence.frameLength = 14400
        self.player.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.flow.withLock { $0.played += 1 }
        }
        if !self.player.isPlaying { self.player.play() }
    }

    private func stopGraph() {
        self.running = false
        if self.hasTap { self.engine.inputNode.removeTap(onBus: 0)
            self.hasTap = false
        }
        self.clearPlayback()
        self.engine.stop()
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        self.flow.withLock { $0.captured += 1 }
        guard self.gate.withLock({ state in
            guard !state.stopped, state.pending < 3 else { return false }
            state.pending += 1
            return true
        }) else { return }
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let copy = CapturedAudio(
            format: buffer.format.streamDescription.pointee,
            frames: buffer.frameLength,
            buffers: source.map { chunk in
                chunk.mData.map { Data(bytes: $0, count: Int(chunk.mDataByteSize)) } ?? Data()
            })
        self.queue.async {
            defer { self.gate.withLock { $0.pending -= 1 } }
            guard self.running, !self.gate.withLock({ $0.stopped }) else { return }
            do {
                try self.encode(copy)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func encode(_ captured: CapturedAudio) throws {
        var description = captured.format
        guard let format = AVAudioFormat(streamDescription: &description),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: captured.frames)
        else { return }
        buffer.frameLength = captured.frames
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destination.count == captured.buffers.count else { return }
        for index in destination.indices {
            guard let bytes = destination[index].mData,
                  captured.buffers[index].count <= Int(destination[index].mDataByteSize) else { return }
            captured.buffers[index].copyBytes(
                to: bytes.assumingMemoryBound(to: UInt8.self),
                count: captured.buffers[index].count)
        }
        guard let resampler = self.resampler, let codec = self.codec, let frame = self.frame,
              buffer.format == resampler.inputFormat else { return }
        let capacity =
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * WatchOpusCodec.sampleRate / buffer.format.sampleRate)) +
            960
        guard let output = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: capacity) else { return }
        _ = try resampler.convert(buffer, to: output)
        for index in 0..<Int(output.frameLength) {
            frame.floatChannelData![0][self.frameOffset] = output.floatChannelData![0][index]
            self.frameOffset += 1
            guard self.frameOffset == Int(WatchOpusCodec.frameCount) else { continue }
            frame.frameLength = WatchOpusCodec.frameCount
            if self.gate.withLock({ $0.muted }) {
                frame.floatChannelData![0].initialize(repeating: 0, count: self.frameOffset)
            }
            if let packet = try codec.encode(frame) { self.onPacket?(packet, self.timestamp) }
            if self.timestamp % 4800 == 0 {
                var energy: Float = 0
                for sample in 0..<self.frameOffset {
                    let value = frame.floatChannelData![0][sample]
                    energy += value * value
                }
                self.onLevel(min(1, sqrt(energy / Float(self.frameOffset)) * 4))
            }
            self.timestamp += UInt64(WatchOpusCodec.frameCount)
            self.frameOffset = 0
        }
    }

    private func clearPlayback() {
        self.playbackGeneration &+= 1
        self.player.stop()
        self.scheduledFrames = 0
    }

    private func observeAudioChanges() {
        let center = NotificationCenter.default
        self.observations.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: self.engine,
            queue: nil)
        { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.running, !self.gate.withLock({ $0.stopped }) else { return }
                do {
                    try self.configureGraph()
                } catch {
                    self.fail(error.localizedDescription)
                }
            }
        })
        #if os(watchOS)
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            self.observations.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] event in
                if name == AVAudioSession.interruptionNotification {
                    // An ended interruption restores availability; it must not terminate a
                    // newly started call that registered while the old interruption ended.
                    let type = event.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber
                    guard type?.uintValue == AVAudioSession.InterruptionType.began.rawValue else { return }
                }
                guard let self else { return }
                self.queue
                    .async { self.fail(String(localized: "Voice was interrupted. Start voice again to continue.")) }
            })
        }
        #endif
    }

    private func fail(_ message: String) {
        guard !self.gate.withLock({ state in let stopped = state.stopped
            state.stopped = true
            return stopped }) else { return }
        let continuation = self.startContinuation
        self.startContinuation = nil
        continuation?.resume(throwing: WatchRealtimeMediaError.unavailable(message))
        let onFailure = self.onFailure
        self.finishStopIfPossible()
        onFailure?(message)
    }

    private func finishStopIfPossible() {
        self.stopGraph()
        self.observations.forEach { NotificationCenter.default.removeObserver($0) }
        self.observations.removeAll()
        let start = self.startContinuation
        self.startContinuation = nil
        start?.resume(throwing: CancellationError())
        // Activation is uncancellable. Retain the lease until its callback drains so a late
        // callback cannot deactivate the replacement session's process-global audio route.
        guard !self.activating else { return }
        if self.ownsLease {
            #if os(watchOS)
            if case .external = self.plan {} else {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            #endif
            Self.lease.withLock { if $0 == self.id { $0 = nil } }
            self.ownsLease = false
        }
        self.codec = nil
        self.resampler = nil
        self.frame = nil
        self.onPacket = nil
        self.onFailure = nil
        let stops = self.stopContinuations
        self.stopContinuations.removeAll()
        stops.forEach { $0.resume() }
    }
}
