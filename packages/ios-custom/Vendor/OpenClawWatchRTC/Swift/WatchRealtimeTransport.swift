// Copiado de OpenClaw (MIT, Copyright (c) 2026 OpenClaw Foundation), commit e5cc2d9,
// apps/ios/WatchApp/Sources/WatchRealtimeTransport.swift. Ver ../Licenses/OpenClaw.txt.
import Darwin
import Foundation
import Network
import OpenClawWatchRTC

enum WatchRealtimeMediaEvent: Sendable {
    case connected
    case audio(Data, timestamp: UInt64)
    case ended(WatchRealtimeMediaFailure)
}

struct WatchRealtimeMediaFailure: LocalizedError, Sendable {
    enum Kind: Sendable { case network, audio, sessionEnded, protocolError }
    let kind: Kind
    let message: String
    var errorDescription: String? {
        self.message
    }
}

enum WatchRealtimeMediaError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        }
    }
}

/// The native engine, timer and Network callbacks have one serial queue owner.
final class WatchRealtimeTransport: @unchecked Sendable {
    private struct Route: Hashable, Sendable {
        let source: NWEndpoint
        let destination: NWEndpoint
    }

    private enum Binding {
        case discover(source: NWEndpoint, destination: NWEndpoint)
        case exact(Route)
        /// OpenCode: o sistema escolhe interface e porta local (utun pelo iPhone ou en0).
        /// byName repete o destino como nome, para o Network.framework sintetizar IPv6 (NAT64).
        case system(destination: NWEndpoint, index: Int, byName: Bool)

        var destination: NWEndpoint {
            switch self {
            case let .discover(_, destination): destination
            case let .exact(route): route.destination
            case let .system(destination, _, _): destination
            }
        }

        var source: NWEndpoint? {
            switch self {
            case let .discover(source, _): source
            case let .exact(route): route.source
            case .system: nil
            }
        }
    }

    /// OpenCode: liga o roteamento pelo sistema (sem fixar interface/porta local).
    static let systemRouting = true
    private let diagnostics = DiagnosticLog()
    private var flowNumbers: [UUID: Int] = [:]
    private var nameFallbacks: Set<Int> = []
    private var remoteOriginals: [NWEndpoint] = []

    /// Linhas de diagnóstico por fluxo UDP (sem IPs completos).
    var diagnosticLines: [String] { diagnostics.lines }

    final class DiagnosticLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        private var counters: [String: Int] = [:]
        private var firstError: String?
        func add(_ line: String) {
            lock.withLock {
                entries.append(line)
                if entries.count > 60 { entries.removeFirst(entries.count - 60) }
            }
        }
        func count(_ key: String) {
            lock.withLock { counters[key, default: 0] += 1 }
        }
        func engineError(_ text: String) {
            lock.withLock { if firstError == nil { firstError = text } }
        }
        var lines: [String] {
            lock.withLock {
                let summary = counters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                return ["counters \(summary)", "firstEngineError \(firstError ?? "-")"] + entries
            }
        }
    }

    private struct PendingCheck {
        let data: Data
        let deadline: DispatchTime
    }

    private struct Flow {
        let connection: NWConnection
        let binding: Binding
        var route: Route?
        var pending: PendingCheck?
    }

    struct RemoteAddress: Sendable {
        let index: Int
        let original: NWEndpoint
        let addresses: [NWEndpoint]
    }

    struct DiscoveryPlan: Sendable {
        let aliases: [(index: Int, address: NWEndpoint)]
        let pairs: [(source: NWEndpoint, destination: NWEndpoint)]
        let destinations: Set<NWEndpoint>
    }

    // is 0.11.0 retains at most 100 candidate pairs. Reject a larger discovery
    // plan instead of silently choosing the first interface or remote endpoint.
    private static let pairBudget = 100
    private let queue = DispatchQueue(label: "ai.openclaw.watch.realtime.media", qos: .userInitiated)
    private let onEvent: @Sendable (WatchRealtimeMediaEvent) -> Void
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var started = false
    private var rtc: OpaquePointer?
    private var timer: DispatchSourceTimer?
    /// OpenCode: armed at ICE Disconnected, cancelled when ICE connects again.
    private var disconnectTimer: DispatchSourceTimer?
    private static let disconnectGrace = DispatchTimeInterval.seconds(10)
    private var flows: [UUID: Flow] = [:]
    private var localCandidates: Set<NWEndpoint> = []
    private var remoteDestinations: Set<NWEndpoint> = []
    private var failedRoutes: Set<Route> = []
    private var activeRoute: Route?
    private var pendingAnswer: CheckedContinuation<Void, Error>?

    init(onEvent: @escaping @Sendable (WatchRealtimeMediaEvent) -> Void) {
        self.onEvent = onEvent
    }

    deinit {
        self.timer?.cancel()
        self.disconnectTimer?.cancel()
        self.flows.values.forEach { $0.connection.cancel() }
        if let rtc { openclaw_rtc_free(rtc) }
    }

    func makeOffer() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    if self.started, !self.cancellationLock.withLock({ self.cancelled }) {
                        continuation
                            .resume(throwing: WatchRealtimeMediaError
                                .unavailable(String(localized: "Voice is already connecting.")))
                        return
                    }
                    do {
                        try continuation.resume(returning: self.begin())
                    } catch { continuation.resume(throwing: error)
                        self.fail(error)
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    func applyAnswer(_ answer: String) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.queue.async {
                    do {
                        let data = Data(answer.utf8)
                        try data.withUnsafeBytes { bytes in
                            try self.mutate("answer") { openclaw_rtc_answer(
                                $0,
                                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                bytes.count) }
                        }
                        let remotes = try self.remoteAddresses()
                        self.pendingAnswer = continuation
                        // getaddrinfo can block. Cancellation joins the RTC queue, never DNS.
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            var resolved: [RemoteAddress] = []
                            for (index, remote) in remotes.enumerated() {
                                guard self?.cancellationLock.withLock({ self?.cancelled == false }) == true
                                else { return }
                                resolved.append(RemoteAddress(
                                    index: index, original: remote, addresses: Self.resolveAddress(remote)))
                            }
                            self?.queue.async { [weak self, resolved] in
                                guard let self, self.pendingAnswer != nil else { return }
                                do {
                                    try self.discoverFlows(resolved)
                                    let completion = try self.cancellationLock.withLock {
                                        guard !self.cancelled else { throw CancellationError() }
                                        defer { self.pendingAnswer = nil }
                                        return self.pendingAnswer
                                    }
                                    completion?.resume()
                                } catch { self.fail(error) }
                            }
                        }
                    } catch { continuation.resume(throwing: error)
                        self.fail(error)
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    func sendOpus(_ data: Data, timestamp: UInt64) {
        self.queue.async {
            // Audio starts muted before signaling; pre-offer frames have no RTC owner.
            guard self.rtc != nil else { return }
            do {
                try data.withUnsafeBytes { bytes in
                    try self.mutate("send_opus") { openclaw_rtc_send_opus(
                        $0,
                        bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        bytes.count,
                        timestamp) }
                }
            } catch { self.fail(error) }
        }
    }

    func cancel() {
        self.cancellationLock.withLock { self.cancelled = true }
        self.queue.async { self.tearDown() }
    }

    func stop() async {
        self.cancellationLock.withLock { self.cancelled = true }
        await withCheckedContinuation { continuation in
            self.queue.async {
                self.tearDown()
                continuation.resume()
            }
        }
    }

    private func begin() throws -> String {
        try self.cancellationLock.withLock {
            guard !self.cancelled else { throw CancellationError() }
            self.started = true
            guard let rtc = openclaw_rtc_create() else {
                throw WatchRealtimeMediaError.unavailable(String(localized: "Unable to initialize secure voice."))
            }
            self.rtc = rtc
        }
        try self.drain()
        // No invented port is advertised. The answer must be ICE-lite, so our
        // authenticated checks let it discover the candidates gathered afterward.
        try self.mutate("offer") { openclaw_rtc_offer($0) }
        return try self.cancellationLock.withLock {
            guard !self.cancelled else { throw CancellationError() }
            var length = 0
            guard let rtc, let bytes = openclaw_rtc_description(rtc, &length),
                  let offer = String(data: Data(bytes: bytes, count: length), encoding: .utf8)
            else {
                throw WatchRealtimeMediaError.unavailable(String(localized: "Voice negotiation could not be created."))
            }
            return offer
        }
    }

    private func remoteAddresses() throws -> [NWEndpoint] {
        var remotes: [NWEndpoint] = []
        for index in 0...Self.pairBudget {
            var address = OpenClawRTCAddress()
            let result = try self.cancellationLock.withLock {
                guard !self.cancelled, let rtc else { throw CancellationError() }
                return openclaw_rtc_remote_address(rtc, index, &address)
            }
            if result == 1 { break }
            guard result == 0 else {
                throw WatchRealtimeMediaError
                    .unavailable(String(localized: "Voice has no supported remote network address."))
            }
            try remotes.append(Self.endpoint(address))
        }
        return remotes
    }

    static func discoveryPlan(remotes: [RemoteAddress], locals: [NWEndpoint]) throws -> DiscoveryPlan {
        var expanded = Set(remotes.map(\.original))
        var endpoints: [NWEndpoint] = []
        var aliases: [(index: Int, address: NWEndpoint)] = []
        for remote in remotes {
            var seen: Set<NWEndpoint> = []
            for address in remote.addresses where seen.insert(address).inserted {
                expanded.insert(address)
                if !endpoints.contains(address) { endpoints.append(address) }
                if !Self.sameFamily(remote.original, address) {
                    aliases.append((remote.index, address))
                }
            }
        }
        guard expanded.count <= Self.pairBudget else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Voice received too many network candidates."))
        }
        var pairs: [(source: NWEndpoint, destination: NWEndpoint)] = []
        var crossPairs = 0
        // Each seed can yield a different local port; include its cross-pairs
        // in the bound before starting any sockets, not just diagonal pairs.
        for source in locals {
            let destinations = endpoints.filter { Self.sameFamily(source, $0) }
            let engineRemotes = expanded.filter { Self.sameFamily(source, $0) }.count
            guard destinations.count <= (Self.pairBudget - crossPairs) / max(1, engineRemotes) else {
                throw WatchRealtimeMediaError
                    .unavailable(String(localized: "Voice cannot use this network candidate set."))
            }
            crossPairs += destinations.count * engineRemotes
            pairs.append(contentsOf: destinations.map { (source, $0) })
        }
        guard !pairs.isEmpty else {
            throw WatchRealtimeMediaFailure(
                kind: .network,
                message: String(localized: "Voice cannot use this network candidate set."))
        }
        return DiscoveryPlan(aliases: aliases, pairs: pairs, destinations: Set(endpoints))
    }

    private func discoverFlows(_ remotes: [RemoteAddress]) throws {
        if Self.systemRouting { return try self.discoverSystemFlows(remotes) }
        // Resolve first, then gather current interfaces and bound the complete ICE/Network plan.
        let plan = try Self.discoveryPlan(remotes: remotes, locals: Self.localAddresses())
        self.remoteDestinations = plan.destinations
        for alias in plan.aliases {
            let address = try Self.nativeAddress(alias.address)
            try self.mutate("resolve_remote_address") { openclaw_rtc_resolve_remote_address($0, alias.index, address) }
        }
        for pair in plan.pairs {
            try self.openFlow(.discover(source: pair.source, destination: pair.destination))
        }
    }

    /// OpenCode: um fluxo por destino remoto (IPv4 original e IPv6 sintetizado pelo resolvedor),
    /// sem interface nem porta local fixas. O endereço local pronto vira candidato ICE.
    private func discoverSystemFlows(_ remotes: [RemoteAddress]) throws {
        self.remoteOriginals = remotes.map(\.original)
        var destinations: [(index: Int, address: NWEndpoint)] = []
        for remote in remotes {
            let addresses = remote.addresses.isEmpty ? [remote.original] : remote.addresses
            for address in addresses where !destinations.contains(where: { $0.address == address }) {
                destinations.append((remote.index, address))
                if !Self.sameFamily(remote.original, address) {
                    let native = try Self.nativeAddress(address)
                    try self.mutate("resolve_remote_address") { openclaw_rtc_resolve_remote_address($0, remote.index, native) }
                }
            }
        }
        // Fluxos por nome usam o IPv4 original como remoto do ICE.
        self.remoteDestinations = Set(destinations.map(\.address)).union(remotes.map(\.original))
        let interfaces = Self.interfaceSummary()
        self.diagnostics.add("plan remotes=\(remotes.count) dests=\(destinations.map { Self.mask($0.address, index: $0.index) }.joined(separator: ",")) ifaces=\(interfaces)")
        for destination in destinations {
            try self.openFlow(.system(destination: destination.address, index: destination.index, byName: false))
        }
    }

    /// Repete um destino IPv4 como nome quando todos os seus fluxos falharam (outra família/NAT64).
    private func openNameFallback(for index: Int) {
        guard Self.systemRouting, !self.nameFallbacks.contains(index), index < self.remoteOriginals.count,
              case let .hostPort(.ipv4(ip), port) = self.remoteOriginals[index] else { return }
        let alive = self.flows.values.contains { flow in
            if case let .system(_, other, _) = flow.binding { return other == index }
            return false
        }
        guard !alive else { return }
        self.nameFallbacks.insert(index)
        let literal = ip.rawValue.map(String.init).joined(separator: ".")
        do {
            try self.openFlow(.system(destination: .hostPort(host: .name(literal, nil), port: port), index: index, byName: true))
        } catch { self.diagnostics.add("r\(index) name-fallback open error \(error.localizedDescription)") }
    }

    private var firstReceive: Set<Int> = []

    /// Candidato local para o ICE na família do remoto. Se o socket é IPv6 (NAT64/CLAT) e o remoto
    /// IPv4, usa o IPv4 mapeado quando houver, senão um IPv4 sentinela único por fluxo: o servidor
    /// ICE-lite descobre o endereço real pelos checks (peer-reflexive), não pelo candidato.
    private static func iceLocal(_ host: NWEndpoint.Host, port: NWEndpoint.Port, remote: NWEndpoint, number: Int) -> NWEndpoint {
        let wantsV4 = if case .hostPort(.ipv4, _) = remote { true } else { false }
        switch host {
        case let .ipv4(address) where wantsV4:
            return .hostPort(host: .ipv4(address), port: port)
        case let .ipv6(address) where !wantsV4:
            return .hostPort(host: .ipv6(address), port: port)
        case let .ipv6(address) where wantsV4:
            let raw = address.rawValue
            if raw.prefix(10).allSatisfy({ $0 == 0 }), raw[10] == 0xFF, raw[11] == 0xFF, let v4 = IPv4Address(raw.suffix(4)) {
                return .hostPort(host: .ipv4(v4), port: port)
            }
            return .hostPort(host: .ipv4(IPv4Address(Data([100, 64, 255, UInt8(min(250, number))]))!), port: port)
        case let .ipv4(address):
            var mapped = Data(repeating: 0, count: 10) + Data([0xFF, 0xFF])
            mapped.append(address.rawValue)
            return .hostPort(host: .ipv6(IPv6Address(mapped)!), port: port)
        default:
            return .hostPort(host: .ipv4(IPv4Address(Data([100, 64, 255, UInt8(min(250, number))]))!), port: port)
        }
    }

    private static func describe(_ endpoint: NWEndpoint?) -> String {
        guard case let .hostPort(host, port)? = endpoint else { return "-" }
        switch host {
        case .ipv4: return "v4:\(port.rawValue)"
        case let .ipv6(address):
            let raw = address.rawValue
            let kind = raw.prefix(10).allSatisfy({ $0 == 0 }) && raw[10] == 0xFF && raw[11] == 0xFF ? "map"
                : raw.prefix(4) == Data([0, 0x64, 0xFF, 0x9B]) ? "wkp64" : "v6"
            return "v6(\(kind)):\(port.rawValue)"
        case .name: return "name:\(port.rawValue)"
        @unknown default: return "?"
        }
    }

    /// Fluxos do sistema guardam a rota do ICE; basta a conexão seguir pronta.
    private func routeIsCurrent(_ flow: Flow, _ route: Route) -> Bool {
        if case .system = flow.binding { return flow.connection.state == .ready }
        return Self.matches(flow.connection, route: route)
    }


    static func isStun(_ data: Data) -> Bool {
        data.count >= 20 && data[data.startIndex] & 0xC0 == 0
            && data[(data.startIndex + 4)..<(data.startIndex + 8)].elementsEqual([0x21, 0x12, 0xA4, 0x42])
    }

    private static func portOf(_ endpoint: NWEndpoint) -> UInt16 {
        guard case let .hostPort(_, port) = endpoint else { return 0 }
        return port.rawValue
    }

    private static func errorCode(_ error: NWError) -> String {
        switch error {
        case let .posix(code): "posix\(code.rawValue)"
        case let .dns(code): "dns\(code)"
        case let .tls(code): "tls\(code)"
        default: "\(error)"
        }
    }

    private static func mask(_ endpoint: NWEndpoint, index: Int) -> String {
        guard case let .hostPort(host, port) = endpoint else { return "r\(index):?" }
        let family = switch host {
        case .ipv4: "v4"
        case .ipv6: "v6"
        case .name: "name"
        @unknown default: "?"
        }
        return "r\(index)\(family):\(port.rawValue)"
    }

    private static func familyOf(_ endpoint: NWEndpoint?) -> String {
        guard case let .hostPort(host, _)? = endpoint else { return "-" }
        return switch host {
        case .ipv4: "v4"
        case .ipv6: "v6"
        case .name: "name"
        @unknown default: "?"
        }
    }

    static func interfaceSummary() -> String {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return "getifaddrs-error" }
        defer { if let first { freeifaddrs(first) } }
        var seen: [String] = []
        var next = first
        while let interface = next?.pointee {
            next = interface.ifa_next
            guard interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let address = interface.ifa_addr else { continue }
            let family = switch Int32(address.pointee.sa_family) {
            case AF_INET: "v4"
            case AF_INET6: Self.host(address) == nil ? "v6ll" : "v6"
            default: ""
            }
            guard !family.isEmpty else { continue }
            let item = "\(String(cString: interface.ifa_name)):\(family)"
            if !seen.contains(item) { seen.append(item) }
        }
        return seen.joined(separator: ",")
    }

    private func mutate(_ op: String = "op", _ operation: (OpaquePointer) -> Int32) throws {
        try self.cancellationLock.withLock {
            guard !self.cancelled else { throw CancellationError() }
            guard let rtc else { throw CancellationError() }
            let code = operation(rtc)
            if code != 0 { self.diagnostics.engineError("\(op)=\(code)") }
            switch code {
            case 0: break
            case -3: throw WatchRealtimeMediaError
                .unavailable(String(localized: "This voice service must support ICE-lite with UDP candidates."))
            case -4: throw WatchRealtimeMediaError
                .unavailable(String(localized: "Voice received too many network candidates."))
            default: throw WatchRealtimeMediaError.unavailable("The secure voice connection failed (\(op)=\(code)).")
            }
        }
        try self.drain()
    }

    private func drain() throws {
        while true {
            var output = OpenClawRTCOutput()
            try self.cancellationLock.withLock {
                guard !self.cancelled, let rtc else { throw CancellationError() }
                let code = openclaw_rtc_poll(rtc, &output)
                guard code == 0 else {
                    self.diagnostics.engineError("poll=\(code)")
                    throw WatchRealtimeMediaError.unavailable("The secure voice connection failed (poll=\(code)).")
                }
            }
            switch output.kind {
            case 0:
                self.scheduleTimeout(milliseconds: output.time)
                return
            case 1:
                guard let bytes = output.bytes else { continue }
                let route = try Route(
                    source: Self.endpoint(output.source),
                    destination: Self.endpoint(output.destination))
                try self.transmit(Data(bytes: bytes, count: output.length), route: route)
            case 2:
                self.diagnostics.add("engine connected (ICE+DTLS)")
                self.onEvent(.connected)
            case 6:
                let names = ["new", "checking", "connected", "completed", "disconnected"]
                self.diagnostics.add("ice \(output.time < 5 ? names[Int(output.time)] : "\(output.time)")")
                if output.time == 2 || output.time == 3, let timer = self.disconnectTimer {
                    timer.cancel()
                    self.disconnectTimer = nil
                    self.diagnostics.add("ice recovered")
                }
            case 3:
                self.diagnostics.count("rx.rtp-opus")
                guard let bytes = output.bytes else { continue }
                self.onEvent(.audio(Data(bytes: bytes, count: output.length), timestamp: output.time))
            case 4:
                // OpenCode: str0m's Disconnected "may trigger intermittently and resolve just as spontaneously";
                // the call ends only when it lasts the grace, not at the first one.
                self.diagnostics.add("ice disconnected")
                if self.disconnectTimer == nil {
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + Self.disconnectGrace)
                    timer.setEventHandler { [weak self] in
                        guard let self, self.disconnectTimer != nil else { return }
                        self.disconnectTimer = nil
                        self.fail(WatchRealtimeMediaFailure(
                            kind: .network,
                            message: String(localized: "Voice lost its network connection.")))
                    }
                    self.disconnectTimer = timer
                    timer.resume()
                }
            case 5: throw WatchRealtimeMediaFailure(kind: .sessionEnded, message: String(localized: "Voice ended."))
            default: break
            }
        }
    }

    private func scheduleTimeout(milliseconds: UInt64) {
        if let timer = self.timer {
            timer.schedule(deadline: .now() + .milliseconds(Int(max(1, milliseconds))))
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(max(1, milliseconds))))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try self.mutate("timeout") { openclaw_rtc_timeout($0) }
            } catch { self.fail(error) }
        }
        self.timer = timer
        timer.resume()
    }

    @discardableResult
    private func openFlow(_ binding: Binding) throws -> UUID {
        guard self.flows.count < Self.pairBudget else {
            throw WatchRealtimeMediaError
                .unavailable(String(localized: "Voice exhausted its network candidate budget."))
        }
        let parameters = NWParameters.udp
        if let source = binding.source {
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = source
        }
        let connection = NWConnection(to: binding.destination, using: parameters)
        let id = UUID()
        self.flows[id] = Flow(connection: connection, binding: binding)
        let number = self.flowNumbers.count + 1
        self.flowNumbers[id] = number
        let label: String = switch binding {
        case let .system(destination, index, byName): "f\(number) \(Self.mask(destination, index: index)) sys\(byName ? "-name" : "")"
        case let .discover(source, destination): "f\(number) \(Self.familyOf(destination)) discover src=\(Self.familyOf(source))"
        case let .exact(route): "f\(number) \(Self.familyOf(route.destination)) exact"
        }
        self.diagnostics.add("\(label) open")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                let interface = connection.currentPath?.availableInterfaces.first.map { "\($0.name)/\($0.type)" } ?? "-"
                switch state {
                case .ready:
                    self.diagnostics.add("f\(number) ready local=\(Self.familyOf(connection.currentPath?.localEndpoint)) remote=\(Self.familyOf(connection.currentPath?.remoteEndpoint)) if=\(interface)")
                case let .failed(error):
                    self.diagnostics.add("f\(number) failed \(Self.errorCode(error)) if=\(interface)")
                case let .waiting(error):
                    self.diagnostics.add("f\(number) waiting \(Self.errorCode(error)) if=\(interface)")
                default: break
                }
                guard self.flows[id] != nil else { return }
                switch state {
                case .ready: self.flowReady(id)
                case let .failed(error), let .waiting(error): self.flowFailed(id, message: error.localizedDescription)
                default: break
                }
            }
        }
        connection.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard let flow = self.flows[id], let route = flow.route else { return }
                if !self.routeIsCurrent(flow, route) {
                    self.flowFailed(id, message: String(localized: "Voice changed its network address."))
                }
            }
        }
        try self.cancellationLock.withLock {
            guard !self.cancelled else { throw CancellationError() }
            connection.start(queue: self.queue)
        }
        return id
    }

    private func flowReady(_ id: UUID) {
        guard var flow = self.flows[id], flow.route == nil else { return }
        let route: Route
        do {
            route = try self.readyRoute(flow, number: self.flowNumbers[id] ?? 0)
        } catch {
            self.diagnostics.add("f\(self.flowNumbers[id] ?? 0) rejected \(error.localizedDescription)")
            self.flowFailed(id, message: error.localizedDescription)
            return
        }
        if let existing = self.flows.first(where: { $0.key != id && $0.value.route == route }) {
            self.flows.removeValue(forKey: id)?.connection.cancel()
            if let pending = flow.pending {
                do {
                    try self.send(pending, id: existing.key)
                } catch { self.fail(error) }
            }
            return
        }
        flow.route = route
        let pending = flow.pending
        flow.pending = nil
        self.flows[id] = flow
        self.failedRoutes.remove(route)
        do {
            // A receive owner and exact ready tuple exist before add_candidate can emit checks.
            try self.receive(id)
            var addsCandidate = false
            switch flow.binding {
            case .discover, .system: addsCandidate = true
            case .exact: break
            }
            if addsCandidate, self.localCandidates.insert(route.source).inserted {
                let native = try Self.nativeAddress(route.source)
                try self.mutate("add_candidate") { openclaw_rtc_add_candidate($0, native) }
            }
            if let pending { try self.send(pending, id: id) }
        } catch { self.fail(error) }
    }

    private func readyRoute(_ flow: Flow, number: Int) throws -> Route {
        if case let .system(requested, index, _) = flow.binding {
            // OpenCode: rota vista pelo ICE, desacoplada do socket. NAT64/CLAT/IPv4 mapeado mudam o que o
            // Network.framework informa; o motor vê sempre (candidato local, IPv4 original da resposta).
            guard case let .hostPort(localHost, localPort)? = flow.connection.currentPath?.localEndpoint,
                  localPort.rawValue != 0 else {
                throw WatchRealtimeMediaError.unavailable(String(localized: "Voice could not bind its local network address."))
            }
            let iceRemote: NWEndpoint = if case .hostPort(.name, _) = requested { self.remoteOriginals[index] } else { requested }
            let iceLocal = Self.iceLocal(localHost, port: localPort, remote: iceRemote, number: number)
            self.diagnostics.add("f\(number) ice local=\(Self.describe(iceLocal)) remote=r\(index)\(Self.familyOf(iceRemote)) nw=\(Self.describe(flow.connection.currentPath?.remoteEndpoint))/\(Self.describe(flow.connection.currentPath?.localEndpoint))")
            return Route(source: iceLocal, destination: iceRemote)
        }
        guard let source = flow.connection.currentPath?.localEndpoint,
              let destination = flow.connection.currentPath?.remoteEndpoint
        else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Voice has no ready network address."))
        }
        _ = try Self.nativeAddress(source)
        _ = try Self.nativeAddress(destination)
        if case let .system(_, _, byName) = flow.binding {
            guard case let .hostPort(_, port) = source, port.rawValue != 0 else {
                throw WatchRealtimeMediaError.unavailable(String(localized: "Voice could not bind its local network address."))
            }
            // NAT64: o Network.framework sintetiza IPv6 para o IPv4 literal pedido. Mesmo porto e
            // família v6 é a rota real; o flowReady registra o alias no motor (resolve_remote_address).
            let synthesized: Bool = {
                guard case let .hostPort(.ipv4, requestedPort) = flow.binding.destination,
                      case let .hostPort(.ipv6, actualPort) = destination else { return false }
                return requestedPort == actualPort
            }()
            guard byName || synthesized || destination == flow.binding.destination else {
                throw WatchRealtimeMediaError.unavailable(String(localized: "Voice changed its remote network address."))
            }
            return Route(source: source, destination: destination)
        }
        guard destination == flow.binding.destination else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Voice changed its remote network address."))
        }
        switch flow.binding {
        case .system: break
        case .discover:
            guard case let .hostPort(actualHost, actualPort) = source,
                  case let .hostPort(requestedHost, _)? = flow.binding.source,
                  actualHost == requestedHost, actualPort.rawValue != 0
            else {
                throw WatchRealtimeMediaError
                    .unavailable(String(localized: "Voice could not bind its local network address."))
            }
        case .exact:
            guard source == flow.binding.source, self.localCandidates.contains(source) else {
                throw WatchRealtimeMediaError
                    .unavailable(String(localized: "Voice could not retain its network address."))
            }
        }
        return Route(source: source, destination: destination)
    }

    private func transmit(_ data: Data, route: Route) throws {
        // str0m 0.23.1 emits DTLS/media only from its nominated send_addr.
        // Only STUN checks may wait for a cross-pair to become ready.
        let isCheck = data.count >= 20 && data[0] & 0xC0 == 0 && data[4..<8].elementsEqual([0x21, 0x12, 0xA4, 0x42])
        // ICE retains signaled originals. They cannot reopen a route the system resolver omitted.
        guard self.remoteDestinations.contains(route.destination) else {
            if isCheck { return }
            throw WatchRealtimeMediaFailure(
                kind: .network,
                message: String(localized: "Voice has no ready media route."))
        }
        if !isCheck { self.activeRoute = route }
        guard !self.failedRoutes.contains(route) else {
            if !isCheck { throw WatchRealtimeMediaFailure(
                kind: .network,
                message: String(localized: "Voice lost its media route.")) }
            return
        }
        let existing = self.flows.first { $0.value.route == route } ?? self.flows.first { _, flow in
            if case let .exact(expected) = flow.binding { return expected == route }
            return false
        }
        let packet = PendingCheck(data: data, deadline: .now() + .milliseconds(1000))
        if let existing, existing.value.route != nil {
            try self.send(packet, id: existing.key)
        } else {
            guard isCheck else {
                throw WatchRealtimeMediaFailure(
                    kind: .network,
                    message: String(localized: "Voice has no ready media route."))
            }
            // OpenCode: com roteamento pelo sistema não se abre fluxo com porta local fixa;
            // checks de pares cruzados são descartados e o ICE fica com os pares diretos.
            if Self.systemRouting, existing == nil { return }
            let id = try (existing?.key ?? self.openFlow(.exact(route)))
            // Expired/superseded UDP checks are intentional non-sends; the ICE
            // owner retains its own retransmission schedule and checklist.
            self.flows[id]?.pending = packet
        }
    }

    private func send(_ packet: PendingCheck, id: UUID) throws {
        let changed = try self.cancellationLock.withLock {
            guard !self.cancelled else { throw CancellationError() }
            guard let flow = self.flows[id], let route = flow.route else { return false }
            guard self.routeIsCurrent(flow, route) else { return true }
            let now = DispatchTime.now()
            guard packet.deadline > now else { return false }
            let remaining = max(1, (packet.deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000)
            let context = NWConnection.ContentContext(identifier: "voice", expiration: UInt64(remaining))
            let number = self.flowNumbers[id] ?? 0
            self.diagnostics.count("tx.f\(number)")
            if Self.isStun(packet.data) { self.diagnostics.count("tx.stun") }
            else if let first = packet.data.first, (20...63).contains(first) { self.diagnostics.count("tx.dtls") }
            // Cancellation closes the same admission lock as native mutation and send.
            // The completion only enqueues work; it cannot reenter this lock inline.
            flow.connection.send(
                content: packet.data,
                contentContext: context,
                completion: .contentProcessed { [weak self] error in
                    guard let self, let error else { return }
                    self.diagnostics.add("f\(self.flowNumbers[id] ?? 0) send-error \(Self.errorCode(error)) bytes=\(packet.data.count)")
                    self.queue.async { self.flowFailed(id, message: error.localizedDescription) }
                })
            return false
        }
        if changed { self.flowFailed(id, message: String(localized: "Voice changed its network address.")) }
    }

    private func receive(_ id: UUID) throws {
        try self.cancellationLock.withLock {
            guard !self.cancelled else { throw CancellationError() }
            guard let flow = self.flows[id], let route = flow.route else { return }
            flow.connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                self.queue.async {
                    guard let current = self.flows[id], current.route == route else { return }
                    guard error == nil, self.routeIsCurrent(current, route) else {
                        self.flowFailed(
                            id,
                            message: error?
                                .localizedDescription ?? String(localized: "Voice changed its network address."))
                        return
                    }
                    do {
                        if let data, !data.isEmpty, data.count <= 2000 {
                            let number = self.flowNumbers[id] ?? 0
                            self.diagnostics.count("rx.f\(number)")
                            if Self.isStun(data) { self.diagnostics.count("rx.stun") }
                            else if let first = data.first, (20...63).contains(first) { self.diagnostics.count("rx.dtls") }
                            if !self.firstReceive.contains(number) {
                                self.firstReceive.insert(number)
                                self.diagnostics.add("f\(number) rx first from=\(Self.familyOf(route.destination)):\(Self.portOf(route.destination)) bytes=\(data.count) stun=\(Self.isStun(data))")
                            }
                            let source = try Self.nativeAddress(route.destination)
                            let destination = try Self.nativeAddress(route.source)
                            try data.withUnsafeBytes { bytes in
                                try self.mutate("receive") { openclaw_rtc_receive(
                                    $0,
                                    source,
                                    destination,
                                    bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                    bytes.count) }
                            }
                        }
                        try self.receive(id)
                    } catch { self.fail(error) }
                }
            }
        }
    }

    private func flowFailed(_ id: UUID, message: String) {
        guard let flow = self.flows.removeValue(forKey: id) else { return }
        flow.connection.cancel()
        if case let .exact(route) = flow.binding { self.failedRoutes.insert(route) }
        if let route = flow.route {
            self.failedRoutes.insert(route)
            if self.activeRoute == route { self.fail(WatchRealtimeMediaFailure(kind: .network, message: message))
                return
            }
            // Never mutate the engine recursively from its Transmit drain. A shared
            // local candidate retires only after its last exact ready owner disappears.
            self.queue.async {
                guard !self.flows.values.contains(where: { $0.route?.source == route.source }),
                      self.localCandidates.remove(route.source) != nil else { return }
                do {
                    let native = try Self.nativeAddress(route.source)
                    try self.mutate("remove_candidate") { openclaw_rtc_remove_candidate($0, native) }
                } catch { self.fail(error) }
            }
        }
        if case let .system(_, index, false) = flow.binding, !self.cancellationLock.withLock({ self.cancelled }) {
            self.openNameFallback(for: index)
        }
        if self.flows.isEmpty { self.fail(WatchRealtimeMediaFailure(kind: .network, message: message)) }
    }

    private func fail(_ error: Error) {
        let newlyClosed = self.cancellationLock.withLock {
            let wasOpen = !self.cancelled
            self.cancelled = true
            return wasOpen
        }
        let failure = error as? WatchRealtimeMediaFailure ??
            WatchRealtimeMediaFailure(kind: .protocolError, message: error.localizedDescription)
        self.tearDown(error: error)
        if newlyClosed { self.onEvent(.ended(failure)) }
    }

    private func tearDown(error: Error = CancellationError()) {
        let pendingAnswer = self.pendingAnswer
        self.pendingAnswer = nil
        self.timer?.cancel()
        self.timer = nil
        self.disconnectTimer?.cancel()
        self.disconnectTimer = nil
        self.flows.values.forEach { $0.connection.cancel() }
        self.flows.removeAll()
        self.localCandidates.removeAll()
        self.remoteDestinations.removeAll()
        self.failedRoutes.removeAll()
        self.activeRoute = nil
        if let rtc { openclaw_rtc_free(rtc) }
        self.rtc = nil
        pendingAnswer?.resume(throwing: error)
    }

    private static func matches(_ connection: NWConnection, route: Route) -> Bool {
        connection.currentPath?.localEndpoint == route.source && connection.currentPath?.remoteEndpoint == route
            .destination
    }

    private static func sameFamily(_ first: NWEndpoint, _ second: NWEndpoint) -> Bool {
        guard case let .hostPort(firstHost, _) = first, case let .hostPort(secondHost, _) = second else { return false }
        switch (firstHost, secondHost) {
        case (.ipv4, .ipv4), (.ipv6, .ipv6): return true
        default: return false
        }
    }

    private static func nativeAddress(_ endpoint: NWEndpoint) throws -> OpenClawRTCAddress {
        guard case let .hostPort(host, port) = endpoint else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Voice received an invalid network address."))
        }
        let bytes: Data
        var result = OpenClawRTCAddress()
        switch host {
        case let .ipv4(address): bytes = address.rawValue
            result.family = 4
        case let .ipv6(address): bytes = address.rawValue
            result.family = 6
        default: throw WatchRealtimeMediaError
            .unavailable(String(localized: "Voice requires a resolved network address."))
        }
        result.port = port.rawValue
        withUnsafeMutableBytes(of: &result.address) { $0.copyBytes(from: bytes) }
        return result
    }

    private static func endpoint(_ address: OpenClawRTCAddress) throws -> NWEndpoint {
        var address = address
        let data = withUnsafeBytes(of: &address.address) { Data($0.prefix(address.family == 4 ? 4 : 16)) }
        let host: NWEndpoint.Host
        if address.family == 4, let ip = IPv4Address(data) {
            host = .ipv4(ip)
        } else if address.family == 6, let ip = IPv6Address(data) {
            host = .ipv6(ip)
        } else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Voice received an invalid network address."))
        }
        guard let port = NWEndpoint.Port(rawValue: address.port) else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Voice received an invalid network port."))
        }
        return .hostPort(host: host, port: port)
    }

    private static func localAddresses() throws -> [NWEndpoint] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else {
            throw WatchRealtimeMediaError
                .unavailable(String(localized: "Voice cannot read the active network addresses."))
        }
        defer { if let first { freeifaddrs(first) } }
        var endpoints: [NWEndpoint] = []
        var next = first
        while let interface = next?.pointee {
            next = interface.ifa_next
            guard interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr else { continue }
            guard let host = Self.host(address) else { continue }
            let endpoint = NWEndpoint.hostPort(host: host, port: .any)
            if !endpoints.contains(endpoint) { endpoints.append(endpoint) }
        }
        return endpoints
    }

    private static func resolveAddress(_ endpoint: NWEndpoint) -> [NWEndpoint] {
        guard case let .hostPort(.ipv4(ip), port) = endpoint else { return [endpoint] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        hints.ai_flags = AI_DEFAULT | AI_NUMERICSERV
        var first: UnsafeMutablePointer<addrinfo>?
        let literal = ip.rawValue.map(String.init).joined(separator: ".")
        guard getaddrinfo(literal, String(port.rawValue), &hints, &first) == 0 else { return [] }
        defer { if let first { freeaddrinfo(first) } }
        var endpoints: [NWEndpoint] = []
        var next = first
        while let resolved = next?.pointee {
            next = resolved.ai_next
            guard let address = resolved.ai_addr, let host = Self.host(address) else { continue }
            let result = NWEndpoint.hostPort(host: host, port: port)
            if !endpoints.contains(result) { endpoints.append(result) }
            // Keep the overflow sentinel: the whole expanded plan is rejected, never truncated.
            if endpoints.count > Self.pairBudget { break }
        }
        return endpoints
    }

    private static func host(_ address: UnsafePointer<sockaddr>) -> NWEndpoint.Host? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            guard let parsed = IPv4Address(Data(bytes: &ip, count: 4)), !parsed.isLinkLocal else { return nil }
            return .ipv4(parsed)
        case AF_INET6:
            var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            guard let parsed = IPv6Address(Data(bytes: &ip, count: 16)), !parsed.isLinkLocal else { return nil }
            return .ipv6(parsed)
        default: return nil
        }
    }
}
