import Foundation

/// Calendar, Reminders and Contacts any OpenCode agent reads on the Mac through `custom.mac`
/// (`packages/plugin-app-custom/src/mac-data`). The Mac app answers with its own macOS grants.
public enum MacDataSource: String, Codable, CaseIterable, Sendable, Identifiable {
  case calendar, reminders, contacts
  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .calendar: "Calendário"
    case .reminders: "Lembretes"
    case .contacts: "Contatos"
    }
  }
  public var detail: String {
    switch self {
    case .calendar: "Eventos de todos os calendários deste Mac, inclusive os do iCloud."
    case .reminders: "Lembretes pendentes e concluídos, com lista, data e prioridade."
    case .contacts: "Busca por nome, telefone ou e-mail: telefones, e-mails, aniversário e endereços."
    }
  }
  public var icon: String {
    switch self {
    case .calendar: "calendar"
    case .reminders: "checklist"
    case .contacts: "person.crop.circle"
    }
  }
}

public enum MacDataPermission: String, Codable, Sendable {
  case granted, notDetermined, denied, restricted
  public var label: String {
    switch self {
    case .granted: "Permitido"
    case .notDetermined: "Permissão não pedida"
    case .denied: "Negado nos Ajustes do Sistema"
    case .restricted: "Restrito"
    }
  }
}

/// The `mac_query` input, forwarded unchanged by the plugin.
public struct MacDataQuery: Codable, Sendable, Equatable {
  public enum Source: String, Codable, Sendable { case calendar, reminders, contacts, status }
  public var source: Source
  public var from: String?
  public var to: String?
  public var calendars: [String]?
  public var lists: [String]?
  public var status: String?
  public var query: String?
  public var limit: Int?
  public init(source: Source, from: String? = nil, to: String? = nil, calendars: [String]? = nil,
    lists: [String]? = nil, status: String? = nil, query: String? = nil, limit: Int? = nil)
  {
    self.source = source
    self.from = from
    self.to = to
    self.calendars = calendars
    self.lists = lists
    self.status = status
    self.query = query
    self.limit = limit
  }
  /// The source the query reads; `status` reads none.
  public var dataSource: MacDataSource? { MacDataSource(rawValue: source.rawValue) }
}

public struct MacDataRequest: Codable, Sendable, Equatable {
  public let requestID: String
  public let deviceID: String
  public let query: MacDataQuery
  public let deadline: Double
  /// The Location whose plugin instance waits for this answer.
  public let directory: String
  public static let eventType = "rpc.custom.mac.request"
  public static func decode(_ event: ConversationEvent) -> MacDataRequest? {
    guard event.type == eventType, let value = event.data.request else { return nil }
    return try? value.decoded(as: MacDataRequest.self)
  }
}

public struct MacDataAttach: Codable, Sendable, Equatable {
  public let deviceID: String
  public let name: String
  public let model: String?
  public let system: String?
  public init(deviceID: String, name: String, model: String?, system: String?) {
    self.deviceID = deviceID
    self.name = name
    self.model = model
    self.system = system
  }
}

/// A failed answer; the plugin turns `reason` into what Alexandre has to do.
public struct MacDataFailure: Error, Sendable, Equatable {
  /// `denied`, `restricted`, `notDetermined`, `disabled`, `invalid` or `failed`.
  public let reason: String
  public let source: String?
  public let message: String
  public init(_ reason: String, source: String?, _ message: String) {
    self.reason = reason
    self.source = source
    self.message = message
  }
  /// The plugin's schema requires `source`, null when no source applies.
  public var json: JSONValue {
    .object(["error": .string(reason), "source": source.map(JSONValue.string) ?? .null, "message": .string(message)])
  }
}

/// Runs one request: a source turned off answers at once, and a collector cannot answer after the server stopped
/// waiting. `collect` receives the moment it must give up, for example on an unanswered permission prompt.
public enum MacDataDispatcher {
  public static func answer(_ request: MacDataRequest, enabled: Set<MacDataSource>, now: Date = .now,
    collect: @escaping @Sendable (MacDataQuery, Date) async throws -> JSONValue) async -> JSONValue
  {
    let source = request.query.source.rawValue
    if let data = request.query.dataSource, !enabled.contains(data) {
      return MacDataFailure("disabled", source: source, "\(source) is turned off in the Mac app.").json
    }
    let deadline = Date(timeIntervalSince1970: request.deadline / 1000 - 0.5)
    let budget = max(0.2, deadline.timeIntervalSince(now))
    return await withTaskGroup(of: JSONValue?.self) { group in
      group.addTask {
        do { return try await collect(request.query, deadline) } catch let failure as MacDataFailure {
          return failure.json
        } catch { return MacDataFailure("failed", source: source, error.localizedDescription).json }
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(budget))
        return nil
      }
      defer { group.cancelAll() }
      return (await group.next() ?? nil) ?? MacDataFailure("failed", source: source, "The Mac could not collect this in time.").json
    }
  }
}

/// Dates as `mac_query` takes and returns them, in the Mac's time zone.
public enum MacDataDates {
  /// `YYYY-MM-DD` is a whole local day: a `to` bound covers it through its end. Date-times without an offset are local.
  public static func parse(_ value: String, end: Bool, calendar: Calendar = .current) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = calendar.timeZone
    for format in [
      "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ss",
      "yyyy-MM-dd'T'HH:mm",
    ] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value) else {
      throw MacDataFailure("invalid", source: nil, "Invalid date \(value)")
    }
    return end ? calendar.date(byAdding: .day, value: 1, to: date) ?? date : date
  }

  /// The calendar's period: today plus 7 days unless given, at most 366 days.
  public static func events(from: String?, to: String?, calendar: Calendar = .current, now: Date = .now) throws
    -> (start: Date, end: Date)
  {
    let start = try from.map { try parse($0, end: false, calendar: calendar) } ?? calendar.startOfDay(for: now)
    let end = try to.map { try parse($0, end: true, calendar: calendar) } ?? start.addingTimeInterval(7 * 86_400)
    try validate(start, end, source: "calendar")
    return (start, end)
  }

  public static func validate(_ start: Date, _ end: Date, source: String) throws {
    guard end > start else { throw MacDataFailure("invalid", source: source, "`to` must be after `from`") }
    guard end.timeIntervalSince(start) <= 366 * 86_400 else {
      throw MacDataFailure("invalid", source: source, "The period is limited to 366 days")
    }
  }

  public static func iso(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = calendar.timeZone
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  public static func day(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = calendar.timeZone
    formatter.formatOptions = [.withFullDate]
    return formatter.string(from: date)
  }
}

/// Local choices for "Ajustes → Dados do Mac": enabled sources (all by default; macOS still asks for each
/// permission), the last answered request per source and a stable identifier for this Mac.
@MainActor public final class MacDataPreferences {
  private let defaults: UserDefaults
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public var deviceID: String {
    if let value = defaults.string(forKey: "OpenCodeMacDataDeviceID") { return value }
    let value = UUID().uuidString
    defaults.set(value, forKey: "OpenCodeMacDataDeviceID")
    return value
  }
  public func enabled(_ source: MacDataSource) -> Bool { defaults.object(forKey: key(source)) as? Bool ?? true }
  public func set(_ source: MacDataSource, enabled: Bool) { defaults.set(enabled, forKey: key(source)) }
  public var enabledSources: Set<MacDataSource> { Set(MacDataSource.allCases.filter(enabled)) }
  public func lastAnswered(_ source: MacDataSource) -> Date? {
    (defaults.object(forKey: "OpenCodeMacDataAnswered." + source.rawValue) as? Double).map(Date.init(timeIntervalSince1970:))
  }
  public func answered(_ source: MacDataSource, at date: Date = .now) {
    defaults.set(date.timeIntervalSince1970, forKey: "OpenCodeMacDataAnswered." + source.rawValue)
  }
  private func key(_ source: MacDataSource) -> String { "OpenCodeMacDataSource." + source.rawValue }
}

public extension OpenCodeClient {
  func macAttach(_ attach: MacDataAttach) async throws {
    let _: JSONValue = try await rpc("custom.mac", "attach", input: attach, timeout: 8)
  }
  func macDetach(deviceID: String) async throws {
    struct Input: Encodable { let deviceID: String }
    let _: JSONValue = try await rpc("custom.mac", "detach", input: Input(deviceID: deviceID), timeout: 4)
  }
  /// Answers through the request's Location, whose plugin instance holds the waiting tool call.
  @discardableResult func macRespond(_ request: MacDataRequest, answer: JSONValue) async throws -> Bool {
    struct Input: Encodable {
      let deviceID: String
      let requestID: String
      let answer: JSONValue
    }
    struct Output: Decodable { let accepted: Bool }
    let output: Output = try await rpc("custom.mac", "respond",
      input: Input(deviceID: request.deviceID, requestID: request.requestID, answer: answer),
      directory: request.directory, timeout: 15)
    return output.accepted
  }
}
