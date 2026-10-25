import Foundation

/// iPhone data the Sessão mestra reads on demand through `custom.device` (`packages/plugin-app-custom/src/device`).
public enum DeviceSource: String, Codable, CaseIterable, Sendable, Identifiable {
  case device, network, location, health, motion, photos
  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .device: "Aparelho"
    case .network: "Rede"
    case .location: "Localização"
    case .health: "Saúde"
    case .motion: "Movimento"
    case .photos: "Fotos"
    }
  }
  public var detail: String {
    switch self {
    case .device: "Bateria, modo de pouca energia, temperatura, armazenamento, modelo e iOS."
    case .network: "Wi-Fi ou celular, rede cara ou limitada."
    case .location: "Posição atual e endereço, só com o app aberto."
    case .health: "Sono, passos, energia ativa, frequência cardíaca em repouso, VFC, treinos e peso."
    case .motion: "Passos, distância, andares e atividade dos últimos 7 dias."
    case .photos: "Data, local e tipo das fotos recentes, com miniaturas."
    }
  }
  public var icon: String {
    switch self {
    case .device: "iphone"
    case .network: "network"
    case .location: "location"
    case .health: "heart"
    case .motion: "figure.walk"
    case .photos: "photo.on.rectangle"
    }
  }
  /// Sources that need no iOS permission start enabled.
  public var enabledByDefault: Bool { self == .device || self == .network }
}

public enum DeviceAuthorization: String, Codable, Sendable {
  case notDetermined, authorized, limited, requested, denied, restricted, unavailable
  public var label: String {
    switch self {
    case .notDetermined: "Permissão não pedida"
    case .authorized: "Permitido"
    case .limited: "Acesso limitado"
    case .requested: "Permissão solicitada"
    case .denied: "Negado nos Ajustes"
    case .restricted: "Restrito"
    case .unavailable: "Indisponível neste aparelho"
    }
  }
  public var usable: Bool { self == .authorized || self == .limited || self == .requested }
}

public struct DeviceSourceState: Codable, Sendable, Equatable {
  public let source: DeviceSource
  public let enabled: Bool
  public let authorization: DeviceAuthorization
  public init(source: DeviceSource, enabled: Bool, authorization: DeviceAuthorization) {
    self.source = source
    self.enabled = enabled
    self.authorization = authorization
  }
}

public enum DeviceMetric: String, Codable, CaseIterable, Sendable {
  case sleep, steps, activeEnergy, restingHeartRate, hrv, workouts, weight
}

public struct DeviceQuery: Codable, Sendable, Equatable {
  public enum Granularity: String, Codable, Sendable { case day, sample }
  public var source: DeviceSource
  public var metrics: [DeviceMetric]?
  public var from: String?
  public var to: String?
  public var granularity: Granularity?
  public var limit: Int?
  public var thumbnails: Bool?
  public init(source: DeviceSource, metrics: [DeviceMetric]? = nil, from: String? = nil, to: String? = nil,
    granularity: Granularity? = nil, limit: Int? = nil, thumbnails: Bool? = nil)
  {
    self.source = source
    self.metrics = metrics
    self.from = from
    self.to = to
    self.granularity = granularity
    self.limit = limit
    self.thumbnails = thumbnails
  }
}

public struct DeviceRequest: Codable, Sendable, Equatable {
  public let requestID: String
  public let deviceID: String
  public let query: DeviceQuery
  public let deadline: Double
  /// The Location whose plugin instance waits for this answer.
  public let directory: String
  public static let eventType = "rpc.custom.device.request"
  public static func decode(_ event: ConversationEvent) -> DeviceRequest? {
    guard event.type == eventType, let value = event.data.request else { return nil }
    return try? value.decoded(as: DeviceRequest.self)
  }
}

public struct DeviceFile: Codable, Sendable, Equatable {
  public let name: String
  public let mime: String
  /// Base64 without a data URI prefix.
  public let data: String
  public init(name: String, mime: String, data: String) {
    self.name = name
    self.mime = mime
    self.data = data
  }
}

public enum DeviceStatus: String, Codable, Sendable {
  case ok, offline, timeout, locked, disabled, denied, unavailable, error
}

public struct DeviceAnswer: Codable, Sendable, Equatable {
  public var status: DeviceStatus
  public var collectedAt: Double?
  public var data: JSONValue?
  public var files: [DeviceFile]?
  public var note: String?
  public var truncated: Bool?
  public init(status: DeviceStatus, collectedAt: Double? = nil, data: JSONValue? = nil, files: [DeviceFile]? = nil,
    note: String? = nil, truncated: Bool? = nil)
  {
    self.status = status
    self.collectedAt = collectedAt
    self.data = data
    self.files = files
    self.note = note
    self.truncated = truncated
  }
  public static func ok<Value: Encodable>(_ value: Value, at date: Date = .now, files: [DeviceFile]? = nil,
    note: String? = nil, truncated: Bool? = nil) -> DeviceAnswer
  {
    do {
      return DeviceAnswer(status: .ok, collectedAt: date.timeIntervalSince1970 * 1000, data: try JSONValue(encoding: value),
        files: files, note: note, truncated: truncated)
    } catch { return .failure(.error, "Could not encode the collected data.") }
  }
  public static func failure(_ status: DeviceStatus, _ note: String) -> DeviceAnswer {
    DeviceAnswer(status: status, note: note)
  }
}

public struct DeviceAttach: Codable, Sendable, Equatable {
  public let deviceID: String
  public let name: String
  public let model: String?
  public let system: String?
  public let sources: [DeviceSourceState]
  public init(deviceID: String, name: String, model: String?, system: String?, sources: [DeviceSourceState]) {
    self.deviceID = deviceID
    self.name = name
    self.model = model
    self.system = system
    self.sources = sources
  }
}

/// Runs one request against the app's collectors: disabled sources answer at once and a slow collector cannot
/// answer after the server stopped waiting.
public enum DeviceDispatcher {
  public static func answer(_ request: DeviceRequest, enabled: Set<DeviceSource>, now: Date = .now,
    collect: @escaping @Sendable (DeviceQuery) async -> DeviceAnswer) async -> DeviceAnswer
  {
    guard enabled.contains(request.query.source) else {
      return .failure(.disabled, "This source is turned off in the app (Você → Dados do iPhone).")
    }
    let budget = max(0.2, request.deadline / 1000 - now.timeIntervalSince1970 - 0.3)
    return await withTaskGroup(of: DeviceAnswer?.self) { group in
      group.addTask { await collect(request.query) }
      group.addTask {
        try? await Task.sleep(for: .seconds(budget))
        return nil
      }
      defer { group.cancelAll() }
      return (await group.next() ?? nil) ?? .failure(.timeout, "The iPhone could not collect this in time.")
    }
  }
}

/// A day range in the iPhone's calendar, from `YYYY-MM-DD` bounds (inclusive). Missing bounds default to the
/// last `defaultDays` days ending today.
public struct DeviceDayRange: Sendable, Equatable {
  public let start: Date
  /// Exclusive end: the start of the day after `to`, or now when `to` is today.
  public let end: Date
  public let days: [String]

  public static func resolve(from: String?, to: String?, defaultDays: Int = 7, maxDays: Int,
    calendar: Calendar = .current, now: Date = .now) -> DeviceDayRange?
  {
    let today = calendar.startOfDay(for: now)
    guard let last = to.map({ day($0, calendar: calendar) }) ?? today,
      let first = from.map({ day($0, calendar: calendar) }) ?? calendar.date(byAdding: .day, value: -(defaultDays - 1), to: min(last, today)),
      first <= last else { return nil }
    let clampedLast = min(last, today)
    let count = (calendar.dateComponents([.day], from: first, to: clampedLast).day ?? 0) + 1
    guard count >= 1, count <= maxDays else { return nil }
    let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }.map { label($0, calendar: calendar) }
    let end = clampedLast == today ? now : calendar.date(byAdding: .day, value: 1, to: clampedLast) ?? now
    return DeviceDayRange(start: first, end: end, days: days)
  }

  public static func label(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func day(_ text: String, calendar: Calendar) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }
}

/// Health aggregation that does not depend on HealthKit types, so it is testable on macOS.
public enum DeviceHealth {
  public struct SleepSample: Sendable, Equatable {
    public let start: Date
    public let end: Date
    /// `inBed`, `awake`, `asleepCore`, `asleepDeep`, `asleepREM` or `asleepUnspecified`.
    public let stage: String
    public let source: String?
    public init(start: Date, end: Date, stage: String, source: String? = nil) {
      self.start = start
      self.end = end
      self.stage = stage
      self.source = source
    }
  }

  public struct SleepNight: Codable, Sendable, Equatable {
    /// The day the night ended (wake-up day).
    public let day: String
    public let start: Date
    public let end: Date
    public let asleepMinutes: Int
    public let inBedMinutes: Int
    public let stages: [String: Int]
  }

  /// Groups samples by the day each night ends (a sample ending before 18:00 belongs to that day, a later one to the
  /// next), sums minutes per stage, and counts asleep time as core + deep + REM + unspecified.
  public static func nights(_ samples: [SleepSample], calendar: Calendar = .current) -> [SleepNight] {
    let grouped = Dictionary(grouping: samples) { sample -> String in
      let hour = calendar.component(.hour, from: sample.end)
      let base = hour >= 18 ? calendar.date(byAdding: .day, value: 1, to: sample.end) ?? sample.end : sample.end
      return DeviceDayRange.label(base, calendar: calendar)
    }
    return grouped.keys.sorted().compactMap { day in
      guard let items = grouped[day], let start = items.map(\.start).min(), let end = items.map(\.end).max() else { return nil }
      var stages: [String: Int] = [:]
      for item in items { stages[item.stage, default: 0] += minutes(item.end.timeIntervalSince(item.start)) }
      let asleep = ["asleepCore", "asleepDeep", "asleepREM", "asleepUnspecified"].reduce(0) { $0 + (stages[$1] ?? 0) }
      return SleepNight(day: day, start: start, end: end, asleepMinutes: asleep, inBedMinutes: stages["inBed"] ?? 0, stages: stages)
    }
  }

  static func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }

  /// The `health` answer; also the locked-iPhone cache (daily data only, protected until first unlock).
  public struct Summary: Codable, Sendable, Equatable {
    public struct Value: Codable, Sendable, Equatable {
      public let day: String
      public let value: Double
      public let min: Double?
      public let max: Double?
      public init(day: String, value: Double, min: Double? = nil, max: Double? = nil) {
        self.day = day
        self.value = value
        self.min = min
        self.max = max
      }
    }
    public struct Workout: Codable, Sendable, Equatable {
      public let day: String
      public let start: Date
      public let end: Date
      public let activity: String
      public let minutes: Int
      public let energyKcal: Double?
      public let distanceKm: Double?
      public let source: String?
      public init(day: String, start: Date, end: Date, activity: String, minutes: Int, energyKcal: Double?,
        distanceKm: Double?, source: String?)
      {
        self.day = day
        self.start = start
        self.end = end
        self.activity = activity
        self.minutes = minutes
        self.energyKcal = energyKcal
        self.distanceKm = distanceKm
        self.source = source
      }
    }
    public struct Sample: Codable, Sendable, Equatable {
      public let start: Date
      public let end: Date
      public let stage: String
      public let source: String?
      public init(start: Date, end: Date, stage: String, source: String?) {
        self.start = start
        self.end = end
        self.stage = stage
        self.source = source
      }
    }
    public var from: String
    public var to: String
    public var timeZone: String
    public var steps: [Value]?
    public var activeEnergyKcal: [Value]?
    public var restingHeartRateBpm: [Value]?
    public var hrvMs: [Value]?
    public var weightKg: [Value]?
    public var sleep: [SleepNight]?
    public var sleepSamples: [Sample]?
    public var workouts: [Workout]?
    public var cachedAt: Date?
    public init(from: String, to: String, timeZone: String) {
      self.from = from
      self.to = to
      self.timeZone = timeZone
    }

    /// Keeps only the requested days and metrics, as a fresh answer for that query would contain.
    public func filtered(days: [String], metrics: Set<DeviceMetric>) -> Summary {
      let wanted = Set(days)
      func values(_ list: [Value]?, _ metric: DeviceMetric) -> [Value]? {
        metrics.contains(metric) ? list?.filter { wanted.contains($0.day) } : nil
      }
      var result = Summary(from: days.first ?? from, to: days.last ?? to, timeZone: timeZone)
      result.steps = values(steps, .steps)
      result.activeEnergyKcal = values(activeEnergyKcal, .activeEnergy)
      result.restingHeartRateBpm = values(restingHeartRateBpm, .restingHeartRate)
      result.hrvMs = values(hrvMs, .hrv)
      result.weightKg = values(weightKg, .weight)
      result.sleep = metrics.contains(.sleep) ? sleep?.filter { wanted.contains($0.day) } : nil
      result.workouts = metrics.contains(.workouts) ? workouts?.filter { wanted.contains($0.day) } : nil
      result.cachedAt = cachedAt
      return result
    }

    public static func decode(_ data: Data) throws -> Summary {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(Summary.self, from: data)
    }
    public func encoded() throws -> Data {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      return try encoder.encode(self)
    }
  }
}

/// CoreMotion activity history as daily minutes per kind.
public enum DeviceMotion {
  public struct Activity: Sendable, Equatable {
    public let start: Date
    /// `stationary`, `walking`, `running`, `automotive`, `cycling` or `unknown`.
    public let kind: String
    public init(start: Date, kind: String) {
      self.start = start
      self.kind = kind
    }
  }

  /// Each activity lasts until the next one (or `end`), split at midnight.
  public static func minutes(_ activities: [Activity], end: Date, calendar: Calendar = .current) -> [String: [String: Int]] {
    let sorted = activities.sorted { $0.start < $1.start }
    var result: [String: [String: Double]] = [:]
    for (index, activity) in sorted.enumerated() {
      var cursor = activity.start
      let stop = index + 1 < sorted.count ? sorted[index + 1].start : end
      while cursor < stop {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)) ?? stop
        let segment = min(midnight, stop)
        result[DeviceDayRange.label(cursor, calendar: calendar), default: [:]][activity.kind, default: 0] +=
          segment.timeIntervalSince(cursor) / 60
        cursor = segment
      }
    }
    return result.mapValues { $0.mapValues { Int($0.rounded()) }.filter { $0.value > 0 } }
  }
}

public extension JSONValue {
  init<Value: Encodable>(encoding value: Value) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
  }
  func decoded<Value: Decodable>(as type: Value.Type) throws -> Value {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}

/// Local choices for "Você → Dados do iPhone": enabled sources, the last answered request per source and a stable
/// device identifier.
@MainActor public final class DevicePreferences {
  private let defaults: UserDefaults
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public var deviceID: String {
    if let value = defaults.string(forKey: "OpenCodeDeviceID") { return value }
    let value = UUID().uuidString
    defaults.set(value, forKey: "OpenCodeDeviceID")
    return value
  }
  public func enabled(_ source: DeviceSource) -> Bool {
    defaults.object(forKey: key(source)) as? Bool ?? source.enabledByDefault
  }
  public func set(_ source: DeviceSource, enabled: Bool) { defaults.set(enabled, forKey: key(source)) }
  public var enabledSources: Set<DeviceSource> { Set(DeviceSource.allCases.filter(enabled)) }
  public func lastAnswered(_ source: DeviceSource) -> Date? {
    (defaults.object(forKey: "OpenCodeDeviceAnswered." + source.rawValue) as? Double).map(Date.init(timeIntervalSince1970:))
  }
  public func answered(_ source: DeviceSource, at date: Date = .now) {
    defaults.set(date.timeIntervalSince1970, forKey: "OpenCodeDeviceAnswered." + source.rawValue)
  }
  private func key(_ source: DeviceSource) -> String { "OpenCodeDeviceSource." + source.rawValue }
}

public extension OpenCodeClient {
  func deviceAttach(_ attach: DeviceAttach) async throws {
    let _: JSONValue = try await rpc("custom.device", "attach", input: attach, timeout: 8)
  }
  func deviceDetach(deviceID: String) async throws {
    struct Input: Encodable { let deviceID: String }
    let _: JSONValue = try await rpc("custom.device", "detach", input: Input(deviceID: deviceID), timeout: 4)
  }
  /// Answers through the request's Location, whose plugin instance holds the waiting tool call.
  @discardableResult func deviceRespond(_ request: DeviceRequest, answer: DeviceAnswer) async throws -> Bool {
    struct Input: Encodable {
      let deviceID: String
      let requestID: String
      let answer: DeviceAnswer
    }
    struct Output: Decodable { let accepted: Bool }
    let output: Output = try await rpc("custom.device", "respond",
      input: Input(deviceID: request.deviceID, requestID: request.requestID, answer: answer),
      directory: request.directory, timeout: 15)
    return output.accepted
  }
}
