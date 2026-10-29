import Foundation
import Testing

@testable import OpenCodeKit

private let calendar: Calendar = {
  var value = Calendar(identifier: .gregorian)
  value.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
  return value
}()

private func event(_ json: String) throws -> ConversationEvent {
  try JSONDecoder().decode(ConversationEvent.self, from: Data(json.utf8))
}

private func request(_ query: MacDataQuery, deadline: Double = 60_000) -> MacDataRequest {
  MacDataRequest(requestID: "r1", deviceID: "m1", query: query, deadline: deadline, directory: "/chats")
}

@Test func macRequestsDecodeFromTheirRpcEventAndOthersAreIgnored() throws {
  let decoded = try #require(MacDataRequest.decode(try event(#"""
    {"type":"rpc.custom.mac.request","data":{"request":{"requestID":"r1","deviceID":"m1","deadline":60000,
    "directory":"/chats","query":{"source":"calendar","from":"2026-10-29","to":"2026-10-29","calendars":["Casa"],"limit":5}}}}
    """#)))
  #expect(decoded == request(MacDataQuery(source: .calendar, from: "2026-10-29", to: "2026-10-29", calendars: ["Casa"],
    limit: 5)))
  #expect(decoded.query.dataSource == .calendar)
  #expect(MacDataQuery(source: .status).dataSource == nil)
  #expect(MacDataRequest.decode(try event(#"""
    {"type":"rpc.custom.device.request","data":{"request":{"requestID":"r1","deviceID":"m1","deadline":1,
    "directory":"/chats","query":{"source":"status"}}}}
    """#)) == nil)
  #expect(MacDataRequest.decode(try event(#"{"type":"rpc.custom.mac.request","data":{"request":{"source":"x"}}}"#)) == nil)
}

@Test func failuresCarryANullSourceWhenNoneApplies() throws {
  let json = String(decoding: try JSONEncoder().encode(MacDataFailure("invalid", source: nil, "Invalid date x").json),
    as: UTF8.self)
  #expect(json.contains(#""source":null"#))
  #expect(json.contains(#""error":"invalid""#))
}

@Test func aSourceTurnedOffAnswersAtOnceWithoutCollecting() async {
  let answer = await MacDataDispatcher.answer(request(MacDataQuery(source: .reminders)), enabled: [.calendar],
    now: Date(timeIntervalSince1970: 0)) { _, _ in
    Issue.record("collected a disabled source")
    return .null
  }
  #expect(answer == MacDataFailure("disabled", source: "reminders", "reminders is turned off in the Mac app.").json)
}

@Test func collectorsGetTheDeadlineAndTheirFailuresBecomeAnswers() async {
  let now = Date(timeIntervalSince1970: 0)
  let ok = await MacDataDispatcher.answer(request(MacDataQuery(source: .status)), enabled: [], now: now) { _, deadline in
    #expect(deadline == Date(timeIntervalSince1970: 59.5))
    return .object(["source": .string("status")])
  }
  #expect(ok == .object(["source": .string("status")]))
  let denied = await MacDataDispatcher.answer(request(MacDataQuery(source: .contacts, query: "Ana")),
    enabled: [.contacts], now: now) { _, _ in throw MacDataFailure("denied", source: "contacts", "denied") }
  #expect(denied == MacDataFailure("denied", source: "contacts", "denied").json)
}

@Test func aSlowCollectorIsCutAtTheDeadline() async {
  let now = Date.now
  let answer = await MacDataDispatcher.answer(
    request(MacDataQuery(source: .calendar), deadline: (now.timeIntervalSince1970 + 0.5) * 1000), enabled: [.calendar],
    now: now
  ) { _, _ in
    try await Task.sleep(for: .seconds(30))
    return .null
  }
  #expect(answer == MacDataFailure("failed", source: "calendar", "The Mac could not collect this in time.").json)
}

@Test func datesAreLocalDaysWithAnInclusiveEnd() throws {
  let day = try MacDataDates.parse("2026-10-29", end: false, calendar: calendar)
  #expect(MacDataDates.iso(day, calendar: calendar) == "2026-10-29T00:00:00-03:00")
  #expect(MacDataDates.iso(try MacDataDates.parse("2026-10-29", end: true, calendar: calendar), calendar: calendar)
    == "2026-10-30T00:00:00-03:00")
  #expect(MacDataDates.iso(try MacDataDates.parse("2026-10-29T14:30", end: true, calendar: calendar), calendar: calendar)
    == "2026-10-29T14:30:00-03:00")
  #expect(MacDataDates.iso(try MacDataDates.parse("2026-10-29T14:30:00Z", end: false, calendar: calendar),
    calendar: calendar) == "2026-10-29T11:30:00-03:00")
  #expect(MacDataDates.day(day, calendar: calendar) == "2026-10-29")
  #expect(throws: MacDataFailure("invalid", source: nil, "Invalid date 29/10/2026")) {
    try MacDataDates.parse("29/10/2026", end: false, calendar: calendar)
  }
}

@Test func theCalendarPeriodDefaultsToAWeekAndIsBounded() throws {
  let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15))!
  let week = try MacDataDates.events(from: nil, to: nil, calendar: calendar, now: now)
  #expect(MacDataDates.iso(week.start, calendar: calendar) == "2026-10-29T00:00:00-03:00")
  #expect(week.end.timeIntervalSince(week.start) == 7 * 86_400)
  let today = try MacDataDates.events(from: "2026-10-29", to: "2026-10-29", calendar: calendar, now: now)
  #expect(today.end.timeIntervalSince(today.start) == 86_400)
  #expect(throws: MacDataFailure("invalid", source: "calendar", "`to` must be after `from`")) {
    try MacDataDates.events(from: "2026-10-29", to: "2026-10-28", calendar: calendar, now: now)
  }
  #expect(throws: MacDataFailure("invalid", source: "calendar", "The period is limited to 366 days")) {
    try MacDataDates.events(from: "2026-01-01", to: "2027-12-31", calendar: calendar, now: now)
  }
}

@MainActor @Test func preferencesEnableEverySourceByDefaultAndKeepOneIdentifier() throws {
  let suite = "MacDataTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = MacDataPreferences(defaults: defaults)
  #expect(preferences.enabledSources == Set(MacDataSource.allCases))
  preferences.set(.contacts, enabled: false)
  #expect(preferences.enabledSources == [.calendar, .reminders])
  #expect(preferences.deviceID == preferences.deviceID)
  #expect(preferences.lastAnswered(.calendar) == nil)
  preferences.answered(.calendar, at: Date(timeIntervalSince1970: 7))
  #expect(preferences.lastAnswered(.calendar) == Date(timeIntervalSince1970: 7))
}
