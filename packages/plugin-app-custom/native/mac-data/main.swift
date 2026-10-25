// Read-only Calendar, Reminders and Contacts queries for the custom plugin's `mac_query` tool.
// Usage: opencode-mac-data '<json request>'; no argument requests every permission (Finder launch).
// Writes one JSON object to stdout: the result, or {"error": reason, "source", "message"}.
import Contacts
import EventKit
import Foundation

// TCC attributes privacy access to the responsible process, normally the launchd server that
// spawned us. Re-spawning with disclaimed responsibility makes this signed bundle its own
// responsible process, so one grant to "OpenCode Mac Data" serves production, sandboxes and Terminal.
let disclaimedFlag = "OPENCODE_MAC_DATA_DISCLAIMED"
let promptSeconds = 50.0
let notesLimit = 500
let itemLimit = 1000
let contactLimit = 100

struct Request: Decodable {
  let source: String
  let from: String?
  let to: String?
  let calendars: [String]?
  let lists: [String]?
  let status: String?
  let query: String?
}

struct Failure: Error {
  let reason: String
  let source: String?
  let message: String
}

var child: pid_t = 0

if ProcessInfo.processInfo.environment[disclaimedFlag] == nil { exit(relaunchDisclaimed()) }
do {
  // LaunchServices may append a legacy -psn_ process serial number when opened from Finder.
  let argument = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-psn_") }
  let request =
    try argument.map { try JSONDecoder().decode(Request.self, from: Data($0.utf8)) }
    ?? Request(source: "authorize", from: nil, to: nil, calendars: nil, lists: nil, status: nil, query: nil)
  write(try handle(request))
} catch let failure as Failure {
  write(["error": failure.reason, "source": failure.source ?? NSNull(), "message": failure.message])
} catch {
  write(["error": "invalid", "source": NSNull(), "message": "Invalid request: \(error)"])
}

func handle(_ request: Request) throws -> [String: Any] {
  switch request.source {
  case "status": return ["source": "status", "permissions": permissions()]
  case "authorize":
    _ = try? authorizeEvents(.event)
    _ = try? authorizeEvents(.reminder)
    _ = try? authorizeContacts()
    return ["source": "authorize", "permissions": permissions()]
  case "calendar": return try calendar(request)
  case "reminders": return try reminders(request)
  case "contacts": return try contacts(request)
  default: throw Failure(reason: "invalid", source: nil, message: "Unknown source \(request.source)")
  }
}

func calendar(_ request: Request) throws -> [String: Any] {
  let store = try authorizeEvents(.event)
  let start = try request.from.map { try parse($0, end: false) } ?? Calendar.current.startOfDay(for: Date())
  let end = try request.to.map { try parse($0, end: true) } ?? start.addingTimeInterval(7 * 86_400)
  try validate(start, end, source: "calendar")
  let available = store.calendars(for: .event)
  let selected = try select(available, names: request.calendars, source: "calendar")
  let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: selected))
    .filter { matches(request.query, [$0.title, $0.location, $0.notes]) }
    .sorted { ($0.startDate, $0.title ?? "") < ($1.startDate, $1.title ?? "") }
  return [
    "source": "calendar",
    "timeZone": TimeZone.current.identifier,
    "from": iso(start),
    "to": iso(end),
    "availableCalendars": available.map(\.title).sorted(),
    "total": events.count,
    "events": events.prefix(itemLimit).map(event),
  ]
}

func event(_ event: EKEvent) -> [String: Any] {
  var item: [String: Any] = [
    "title": event.title ?? "",
    "start": event.isAllDay ? day(event.startDate) : iso(event.startDate),
    "end": event.isAllDay ? day(event.endDate) : iso(event.endDate),
    "allDay": event.isAllDay,
    "calendar": event.calendar?.title ?? "",
  ]
  if let account = event.calendar?.source?.title { item["account"] = account }
  if let location = nonEmpty(event.location) { item["location"] = location }
  if let notes = nonEmpty(event.notes) { item["notes"] = String(notes.prefix(notesLimit)) }
  if let url = event.url?.absoluteString { item["url"] = url }
  if let attendees = event.attendees, !attendees.isEmpty {
    item["attendees"] = attendees.prefix(20).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
  }
  if event.hasRecurrenceRules { item["recurring"] = true }
  if event.status == .canceled { item["canceled"] = true }
  return item
}

func reminders(_ request: Request) throws -> [String: Any] {
  let store = try authorizeEvents(.reminder)
  let status = request.status ?? "pending"
  let start = try request.from.map { try parse($0, end: false) }
  let end = try request.to.map { try parse($0, end: true) }
  if let start, let end { try validate(start, end, source: "reminders") }
  let available = store.calendars(for: .reminder)
  let selected = try select(available, names: request.lists, source: "reminders")
  let predicates = [
    status == "completed"
      ? nil
      : store.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: selected),
    status == "pending"
      ? nil
      : store.predicateForCompletedReminders(
        withCompletionDateStarting: start ?? Date().addingTimeInterval(-30 * 86_400), ending: end ?? Date(),
        calendars: selected),
  ].compactMap { $0 }
  let items = try predicates.flatMap { try fetch(store, $0) }
    .filter { matches(request.query, [$0.title, $0.notes]) }
    .sorted(by: reminderOrder)
  return [
    "source": "reminders",
    "timeZone": TimeZone.current.identifier,
    "status": status,
    "availableLists": available.map(\.title).sorted(),
    "total": items.count,
    "reminders": items.prefix(itemLimit).map(reminder),
  ]
}

func fetch(_ store: EKEventStore, _ predicate: NSPredicate) throws -> [EKReminder] {
  let done = DispatchSemaphore(value: 0)
  var result: [EKReminder] = []
  store.fetchReminders(matching: predicate) { reminders in
    result = reminders ?? []
    done.signal()
  }
  guard done.wait(timeout: .now() + 30) == .success else {
    throw Failure(reason: "failed", source: "reminders", message: "Reminders did not answer within 30 seconds")
  }
  return result
}

func reminderOrder(_ a: EKReminder, _ b: EKReminder) -> Bool {
  if a.isCompleted != b.isCompleted { return !a.isCompleted }
  if a.isCompleted { return (a.completionDate ?? .distantPast) > (b.completionDate ?? .distantPast) }
  let left = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
  let right = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
  return (left, a.title ?? "") < (right, b.title ?? "")
}

func reminder(_ reminder: EKReminder) -> [String: Any] {
  var item: [String: Any] = [
    "title": reminder.title ?? "",
    "list": reminder.calendar?.title ?? "",
    "completed": reminder.isCompleted,
  ]
  if let due = reminder.dueDateComponents, let date = Calendar.current.date(from: due) {
    item["due"] = due.hour == nil ? day(date) : iso(date)
  }
  if let completed = reminder.completionDate { item["completedAt"] = iso(completed) }
  if (1...4).contains(reminder.priority) { item["priority"] = "high" }
  if reminder.priority == 5 { item["priority"] = "medium" }
  if (6...9).contains(reminder.priority) { item["priority"] = "low" }
  if let notes = nonEmpty(reminder.notes) { item["notes"] = String(notes.prefix(notesLimit)) }
  if let url = reminder.url?.absoluteString { item["url"] = url }
  return item
}

func contacts(_ request: Request) throws -> [String: Any] {
  let store = try authorizeContacts()
  guard let query = nonEmpty(request.query?.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    throw Failure(reason: "invalid", source: "contacts", message: "Contacts need a name, phone or e-mail query")
  }
  let digits = query.filter(\.isNumber)
  let predicate =
    query.contains("@")
    ? CNContact.predicateForContacts(matchingEmailAddress: query)
    : digits.count >= 4 && query.allSatisfy({ $0.isNumber || " +-().".contains($0) })
      ? CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
      : CNContact.predicateForContacts(matchingName: query)
  let keys: [CNKeyDescriptor] =
    [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)] + [
      CNContactNicknameKey, CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey,
      CNContactEmailAddressesKey, CNContactBirthdayKey, CNContactPostalAddressesKey,
    ].map { $0 as CNKeyDescriptor }
  let found = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
  return [
    "source": "contacts",
    "timeZone": TimeZone.current.identifier,
    "total": found.count,
    "contacts": found.prefix(contactLimit).map(contact),
  ]
}

func contact(_ contact: CNContact) -> [String: Any] {
  var item: [String: Any] = [
    "name": CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName,
    "phones": contact.phoneNumbers.map { ["label": label($0.label), "value": $0.value.stringValue] },
    "emails": contact.emailAddresses.map { ["label": label($0.label), "value": $0.value as String] },
  ]
  if let nickname = nonEmpty(contact.nickname) { item["nickname"] = nickname }
  if let organization = nonEmpty(contact.organizationName) { item["organization"] = organization }
  if let title = nonEmpty(contact.jobTitle) { item["jobTitle"] = title }
  if let birthday = contact.birthday, let month = birthday.month, let dayOfMonth = birthday.day {
    item["birthday"] =
      birthday.year.map { String(format: "%04d-%02d-%02d", $0, month, dayOfMonth) }
      ?? String(format: "--%02d-%02d", month, dayOfMonth)
  }
  let addresses = contact.postalAddresses.map {
    [
      "label": label($0.label),
      "value": CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)
        .replacingOccurrences(of: "\n", with: ", "),
    ]
  }
  if !addresses.isEmpty { item["addresses"] = addresses }
  return item
}

func authorizeEvents(_ type: EKEntityType) throws -> EKEventStore {
  let source = type == .event ? "calendar" : "reminders"
  if EKEventStore.authorizationStatus(for: type) == .notDetermined {
    let done = DispatchSemaphore(value: 0)
    let store = EKEventStore()
    let completion: EKEventStoreRequestAccessCompletionHandler = { _, _ in done.signal() }
    if type == .event { store.requestFullAccessToEvents(completion: completion) }
    if type == .reminder { store.requestFullAccessToReminders(completion: completion) }
    _ = done.wait(timeout: .now() + promptSeconds)
  }
  let status = eventStatus(EKEventStore.authorizationStatus(for: type))
  guard status == "granted" else { throw denied(source, status) }
  return EKEventStore()
}

func authorizeContacts() throws -> CNContactStore {
  let store = CNContactStore()
  if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
    let done = DispatchSemaphore(value: 0)
    store.requestAccess(for: .contacts) { _, _ in done.signal() }
    _ = done.wait(timeout: .now() + promptSeconds)
  }
  let status = contactStatus(CNContactStore.authorizationStatus(for: .contacts))
  guard status == "granted" else { throw denied("contacts", status) }
  return store
}

func permissions() -> [String: String] {
  [
    "calendar": eventStatus(EKEventStore.authorizationStatus(for: .event)),
    "reminders": eventStatus(EKEventStore.authorizationStatus(for: .reminder)),
    "contacts": contactStatus(CNContactStore.authorizationStatus(for: .contacts)),
  ]
}

func eventStatus(_ status: EKAuthorizationStatus) -> String {
  switch status {
  case .fullAccess: return "granted"
  case .notDetermined: return "notDetermined"
  case .restricted: return "restricted"
  case .denied, .writeOnly: return "denied"
  @unknown default: return "denied"
  }
}

func contactStatus(_ status: CNAuthorizationStatus) -> String {
  switch status {
  case .authorized: return "granted"
  case .notDetermined: return "notDetermined"
  case .restricted: return "restricted"
  case .denied: return "denied"
  @unknown default: return "denied"
  }
}

func denied(_ source: String, _ status: String) -> Failure {
  Failure(
    reason: status, source: source,
    message: status == "notDetermined"
      ? "The macOS permission prompt for OpenCode Mac Data was not answered"
      : "macOS \(status) access for OpenCode Mac Data")
}

func select(_ calendars: [EKCalendar], names: [String]?, source: String) throws -> [EKCalendar]? {
  guard let names, !names.isEmpty else { return nil }
  let wanted = Set(names.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) })
  let selected = calendars.filter {
    wanted.contains($0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
  }
  guard !selected.isEmpty else {
    throw Failure(
      reason: "invalid", source: source,
      message: "None of \(names.joined(separator: ", ")) exists. Available: "
        + calendars.map(\.title).sorted().joined(separator: ", "))
  }
  return selected
}

func matches(_ query: String?, _ fields: [String?]) -> Bool {
  guard let query = nonEmpty(query) else { return true }
  return fields.contains { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
}

func validate(_ start: Date, _ end: Date, source: String) throws {
  guard end > start else { throw Failure(reason: "invalid", source: source, message: "`to` must be after `from`") }
  guard end.timeIntervalSince(start) <= 366 * 86_400 else {
    throw Failure(reason: "invalid", source: source, message: "The period is limited to 366 days")
  }
}

/// Date-only values are local days; `to` includes its whole day. Times without an offset are local.
func parse(_ value: String, end: Bool) throws -> Date {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.timeZone = TimeZone.current
  for format in [
    "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm",
  ] {
    formatter.dateFormat = format
    if let date = formatter.date(from: value) { return date }
  }
  formatter.dateFormat = "yyyy-MM-dd"
  guard let date = formatter.date(from: value) else {
    throw Failure(reason: "invalid", source: nil, message: "Invalid date \(value)")
  }
  return end ? Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date : date
}

func iso(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.timeZone = TimeZone.current
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}

func day(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.timeZone = TimeZone.current
  formatter.formatOptions = [.withFullDate]
  return formatter.string(from: date)
}

func label(_ value: String?) -> String {
  value.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
}

func nonEmpty(_ value: String?) -> String? {
  guard let value, !value.isEmpty else { return nil }
  return value
}

func write(_ object: [String: Any]) {
  let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    ?? Data("{\"error\":\"failed\",\"source\":null,\"message\":\"Unserializable result\"}".utf8)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

func relaunchDisclaimed() -> Int32 {
  typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim"),
    let executable = Bundle.main.executablePath
  else {
    write(["error": "failed", "source": NSNull(), "message": "Cannot disclaim responsibility on this macOS"])
    return 1
  }
  var attributes: posix_spawnattr_t?
  posix_spawnattr_init(&attributes)
  defer { posix_spawnattr_destroy(&attributes) }
  _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
  setenv(disclaimedFlag, "1", 1)
  let arguments = CommandLine.arguments.map { strdup($0) } + [nil]
  defer { arguments.forEach { free($0) } }
  let spawned = posix_spawn(&child, executable, nil, &attributes, arguments, environ)
  guard spawned == 0 else {
    write(["error": "failed", "source": NSNull(), "message": "Cannot start the helper: \(String(cString: strerror(spawned)))"])
    return 1
  }
  for signal in [SIGTERM, SIGINT, SIGHUP] { Darwin.signal(signal) { kill(child, $0) } }
  var status: Int32 = 0
  while waitpid(child, &status, 0) == -1 && errno == EINTR {}
  return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
}
