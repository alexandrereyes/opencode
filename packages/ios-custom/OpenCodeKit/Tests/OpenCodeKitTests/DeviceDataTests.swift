import Foundation
import Testing

@testable import OpenCodeKit

private let calendar: Calendar = {
  var value = Calendar(identifier: .gregorian)
  value.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
  return value
}()

private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
  calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private func event(_ json: String) throws -> ConversationEvent {
  try JSONDecoder().decode(ConversationEvent.self, from: Data(json.utf8))
}

@Test func deviceRequestsDecodeFromTheirRpcEventAndOthersAreIgnored() throws {
  let request = try #require(DeviceRequest.decode(try event(#"""
    {"type":"rpc.custom.device.request","data":{"request":{"requestID":"r1","deviceID":"d1","deadline":1792800005000,
    "directory":"/Users/a/chats","query":{"source":"health","metrics":["sleep","steps"],"from":"2026-10-19",
    "to":"2026-10-25","granularity":"day"}}}}
    """#)))
  #expect(request == DeviceRequest(requestID: "r1", deviceID: "d1",
    query: DeviceQuery(source: .health, metrics: [.sleep, .steps], from: "2026-10-19", to: "2026-10-25", granularity: .day),
    deadline: 1_792_800_005_000, directory: "/Users/a/chats"))
  #expect(DeviceRequest.decode(try event(#"{"type":"rpc.custom.preferences.updated","data":{"revision":2}}"#)) == nil)
  #expect(DeviceRequest.decode(try event(#"{"type":"rpc.custom.device.request","data":{"request":{"source":"x"}}}"#)) == nil)
}

@Test func answersEncodeTheRpcContractWithoutAbsentFields() throws {
  struct Battery: Encodable { let level: Double; let charging: Bool }
  let answer = DeviceAnswer.ok(Battery(level: 0.8, charging: true), at: Date(timeIntervalSince1970: 5),
    files: [DeviceFile(name: "IMG_1.jpg", mime: "image/jpeg", data: "AAAA")])
  let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(answer)) as? [String: Any])
  #expect(Set(json.keys) == ["status", "collectedAt", "data", "files"])
  #expect(json["status"] as? String == "ok")
  #expect(json["collectedAt"] as? Double == 5000)
  #expect((json["data"] as? [String: Any])?["level"] as? Double == 0.8)
  let failure = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(
    DeviceAnswer.failure(.locked, "iPhone locked"))) as? [String: Any])
  #expect(failure as NSDictionary == ["status": "locked", "note": "iPhone locked"] as NSDictionary)
}

@Test func dispatchAnswersDisabledSourcesAtOnceAndStopsAtTheDeadline() async {
  let request = DeviceRequest(requestID: "r", deviceID: "d", query: DeviceQuery(source: .photos),
    deadline: Date.now.timeIntervalSince1970 * 1000 + 600, directory: "/")
  let disabled = await DeviceDispatcher.answer(request, enabled: [.device]) { _ in .ok(["never": true]) }
  #expect(disabled.status == .disabled)
  let collected = await DeviceDispatcher.answer(request, enabled: [.photos]) { query in .ok(["source": query.source.rawValue]) }
  #expect(collected.status == .ok)
  #expect(collected.data == .object(["source": .string("photos")]))
  let started = ContinuousClock.now
  let slow = await DeviceDispatcher.answer(request, enabled: [.photos]) { _ in
    try? await Task.sleep(for: .seconds(5))
    return .ok(["late": true])
  }
  #expect(slow.status == .timeout)
  #expect(ContinuousClock.now - started < .seconds(2))
}

@Test func dayRangesDefaultToTheLastWeekAndRejectRangesBeyondTheLimit() throws {
  let now = date(25, 14, 30)
  let week = try #require(DeviceDayRange.resolve(from: nil, to: nil, maxDays: 90, calendar: calendar, now: now))
  #expect(week.days == ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"])
  #expect(week.start == date(19, 0))
  #expect(week.end == now)
  let past = try #require(DeviceDayRange.resolve(from: "2026-10-01", to: "2026-10-02", maxDays: 90, calendar: calendar, now: now))
  #expect(past.days == ["2026-10-01", "2026-10-02"])
  #expect(past.end == date(3, 0))
  let future = try #require(DeviceDayRange.resolve(from: "2026-10-24", to: "2026-10-30", maxDays: 90, calendar: calendar, now: now))
  #expect(future.days == ["2026-10-24", "2026-10-25"])
  #expect(DeviceDayRange.resolve(from: "2026-07-01", to: "2026-10-25", maxDays: 90, calendar: calendar, now: now) == nil)
  #expect(DeviceDayRange.resolve(from: "2026-10-25", to: "2026-10-20", maxDays: 90, calendar: calendar, now: now) == nil)
  #expect(DeviceDayRange.resolve(from: "2026-10", to: nil, maxDays: 90, calendar: calendar, now: now) == nil)
}

@Test func sleepSamplesBecomeNightsByWakeDayWithStageMinutes() {
  let samples = [
    DeviceHealth.SleepSample(start: date(23, 22, 50), end: date(24, 6, 40), stage: "inBed"),
    DeviceHealth.SleepSample(start: date(23, 23, 0), end: date(24, 1, 0), stage: "asleepCore"),
    DeviceHealth.SleepSample(start: date(24, 1, 0), end: date(24, 2, 30), stage: "asleepDeep"),
    DeviceHealth.SleepSample(start: date(24, 2, 30), end: date(24, 2, 40), stage: "awake"),
    DeviceHealth.SleepSample(start: date(24, 2, 40), end: date(24, 4, 10), stage: "asleepREM"),
    DeviceHealth.SleepSample(start: date(24, 4, 10), end: date(24, 6, 30), stage: "asleepCore"),
    DeviceHealth.SleepSample(start: date(24, 14, 0), end: date(24, 14, 30), stage: "asleepUnspecified"),
    DeviceHealth.SleepSample(start: date(24, 23, 30), end: date(25, 7, 0), stage: "asleepUnspecified"),
  ]
  let nights = DeviceHealth.nights(samples, calendar: calendar)
  #expect(nights.map(\.day) == ["2026-10-24", "2026-10-25"])
  #expect(nights[0].stages == ["inBed": 470, "asleepCore": 260, "asleepDeep": 90, "awake": 10, "asleepREM": 90, "asleepUnspecified": 30])
  #expect(nights[0].asleepMinutes == 470)
  #expect(nights[0].inBedMinutes == 470)
  #expect(nights[0].start == date(23, 22, 50))
  #expect(nights[1].asleepMinutes == 450)
}

@Test func theLockedHealthCacheAnswersOnlyTheRequestedDaysAndMetrics() throws {
  var summary = DeviceHealth.Summary(from: "2026-07-28", to: "2026-10-25", timeZone: "America/Sao_Paulo")
  summary.steps = [.init(day: "2026-10-23", value: 9000), .init(day: "2026-10-24", value: 7000), .init(day: "2026-10-25", value: 3000)]
  summary.hrvMs = [.init(day: "2026-10-24", value: 48, min: 30, max: 70)]
  summary.workouts = [.init(day: "2026-10-24", start: date(24, 7), end: date(24, 7, 45), activity: "running", minutes: 45,
    energyKcal: 420, distanceKm: 7.1, source: "Apple Watch")]
  summary.cachedAt = date(25, 9)
  let restored = try DeviceHealth.Summary.decode(try summary.encoded())
  #expect(restored == summary)
  let filtered = restored.filtered(days: ["2026-10-24", "2026-10-25"], metrics: [.steps, .workouts])
  #expect(filtered.from == "2026-10-24")
  #expect(filtered.steps?.map(\.day) == ["2026-10-24", "2026-10-25"])
  #expect(filtered.hrvMs == nil)
  #expect(filtered.workouts?.count == 1)
  #expect(filtered.cachedAt == date(25, 9))
}

@Test func motionActivitiesSplitIntoDailyMinutesAtMidnight() {
  let minutes = DeviceMotion.minutes([
    DeviceMotion.Activity(start: date(24, 23, 30), kind: "walking"),
    DeviceMotion.Activity(start: date(25, 0, 15), kind: "stationary"),
    DeviceMotion.Activity(start: date(25, 8, 0), kind: "automotive"),
  ], end: date(25, 8, 40), calendar: calendar)
  #expect(minutes == ["2026-10-24": ["walking": 30], "2026-10-25": ["walking": 15, "stationary": 465, "automotive": 40]])
}

@Test func iphoneToolsShowTheirSourceInTheConversation() throws {
  func part(_ name: String, _ input: String) throws -> ConversationPart {
    try JSONDecoder().decode(ConversationPart.self, from: Data(
      #"{"type":"tool","name":"\#(name)","state":{"status":"completed","input":\#(input)}}"#.utf8))
  }
  let query = try part("iphone_query", #"{"source":"health","metrics":["sleep"]}"#)
  #expect(query.summary(now: 0) == "Consultou o iPhone · Saúde")
  #expect(query.contextSummary == "Consultou o iPhone · Saúde")
  #expect(query.icon == "iphone")
  #expect(query.groupTitle == "Consultou o iPhone")
  #expect(try part("iphone_status", "{}").summary(now: 0) == "Consultou o iPhone · estado")
  let call = try event(#"{"type":"session.tool.called","data":{"sessionID":"s","name":"iphone_query","input":{"source":"device"}}}"#)
  #expect(VoiceMasterProgress.describe(call) == "A mestra está consultando seu iPhone.")
}

@MainActor @Test func preferencesKeepAStableDeviceAndDefaultOnlyPermissionFreeSources() throws {
  let defaults = try #require(UserDefaults(suiteName: "DeviceDataTests-\(UUID().uuidString)"))
  let preferences = DevicePreferences(defaults: defaults)
  #expect(preferences.deviceID == preferences.deviceID)
  #expect(preferences.enabledSources == [.device, .network])
  preferences.set(.health, enabled: true)
  preferences.set(.device, enabled: false)
  #expect(preferences.enabledSources == [.network, .health])
  #expect(preferences.lastAnswered(.health) == nil)
  preferences.answered(.health, at: Date(timeIntervalSince1970: 10))
  #expect(preferences.lastAnswered(.health) == Date(timeIntervalSince1970: 10))
}
