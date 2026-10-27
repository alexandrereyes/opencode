// Copiado de OpenClaw (MIT, Copyright (c) 2026 OpenClaw Foundation), commit e5cc2d9,
// apps/ios/WatchApp/Sources/WatchRealtimeMediaSession.swift. Ver ../Licenses/OpenClaw.txt.
import AVFAudio
import Foundation
import Synchronization

enum WatchRealtimeSessionEvent: Sendable {
    case connected
    case inputLevel(Float)
    case outputLevel(Float) // OpenCode
    case ended(WatchRealtimeMediaFailure)
}

// OpenCode: contadores de pacotes Opus enviados/recebidos (alteração local).
final class WatchRealtimePacketCounters: Sendable {
    let value = Mutex((sent: 0, received: 0))
}

/// Audio and transport keep their own serial owners. No PCM or packet callbacks run on
/// the main actor; the call controller only receives connection state and metered levels.
final class WatchRealtimeMediaSession: Sendable {
    private enum Phase { case idle, starting, active, stopped }
    private final class Lifecycle: Sendable {
        let phase = Mutex(Phase.idle)

        func finish() -> Bool {
            self.phase.withLock { phase in
                guard phase != .stopped else { return false }
                phase = .stopped
                return true
            }
        }
    }

    private let audio: WatchRealtimeAudioIO
    private let transport: WatchRealtimeTransport
    private let onEvent: @Sendable (WatchRealtimeSessionEvent) -> Void
    private let lifecycle: Lifecycle
    let counters = WatchRealtimePacketCounters()

    var audioFlow: WatchRealtimeAudioIO.Flow { audio.flow.withLock { $0 } }
    var transportDiagnostics: [String] { transport.diagnosticLines }


    init(plan: WatchRealtimeAudioIO.Plan = .duplex, onEvent: @escaping @Sendable (WatchRealtimeSessionEvent) -> Void) {
        self.onEvent = onEvent
        let lifecycle = Lifecycle()
        self.lifecycle = lifecycle
        let counters = self.counters
        let audio = WatchRealtimeAudioIO(plan: plan, onLevel: {
            if lifecycle.phase.withLock({ $0 == .active }) { onEvent(.inputLevel($0)) }
        }, onOutputLevel: { onEvent(.outputLevel($0)) })
        self.audio = audio
        self.transport = WatchRealtimeTransport { [weak audio] event in
            guard lifecycle.phase.withLock({ $0 != .stopped }) else { return }
            switch event {
            case .connected: onEvent(.connected)
            case let .audio(packet, _):
                counters.value.withLock { $0.received += 1 }
                audio?.play(packet)
            case let .ended(message):
                let shouldNotify = lifecycle.finish()
                audio?.cancel()
                if shouldNotify { onEvent(.ended(message)) }
            }
        }
    }

    deinit {
        self.cancel()
    }

    func startAudio() async throws {
        guard self.lifecycle.phase.withLock({ phase in
            guard phase == .idle else { return false }
            phase = .starting
            return true
        })
        else {
            throw WatchRealtimeMediaError
                .unavailable(String(localized: "This voice session has already started or stopped."))
        }
        do {
            let allowed = await PermissionRequestBridge.awaitRequest {
                AVAudioApplication.requestRecordPermission(completionHandler: $0)
            }
            try Task.checkCancellation()
            guard allowed else {
                throw WatchRealtimeMediaError
                    .unavailable(String(localized: "Allow microphone access in Settings to start voice."))
            }
            try await self.audio.start(
                onPacket: { [transport = self.transport, counters = self.counters] in
                    counters.value.withLock { $0.sent += 1 }
                    transport.sendOpus($0, timestamp: $1)
                },
                onFailure: { [weak self] message in
                    guard let self else { return }
                    let shouldNotify = self.lifecycle.finish()
                    self.transport.cancel()
                    if shouldNotify { self.onEvent(.ended(WatchRealtimeMediaFailure(kind: .audio, message: message))) }
                })
            try Task.checkCancellation()
            guard self.lifecycle.phase.withLock({ phase in
                guard phase == .starting else { return false }
                phase = .active
                return true
            }) else { throw CancellationError() }
        } catch {
            await self.stop()
            throw error
        }
    }

    func makeOffer() async throws -> String {
        guard self.lifecycle.phase.withLock({ $0 == .active }) else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Activate voice audio before connecting."))
        }
        return try await self.transport.makeOffer()
    }

    func applyAnswer(_ sdp: String) async throws {
        try await self.transport.applyAnswer(sdp)
    }

    func setMuted(_ muted: Bool) {
        self.audio.setMuted(muted)
    }

    func cancel() {
        _ = self.lifecycle.finish()
        self.audio.cancel()
        self.transport.cancel()
    }

    func stop() async {
        self.cancel()
        await self.audio.stop()
        await self.transport.stop()
    }
}
