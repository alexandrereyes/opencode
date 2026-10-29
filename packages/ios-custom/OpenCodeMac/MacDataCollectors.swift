import Contacts
import EventKit
import OpenCodeKit

/// Reads Calendar, Reminders and Contacts for `custom.mac`, off the main actor and read-only.
actor MacDataCollectors {
  private static let notesLimit = 500
  private var events = EKEventStore()

  nonisolated static func permission(_ source: MacDataSource) -> MacDataPermission {
    switch source {
    case .calendar: permission(EKEventStore.authorizationStatus(for: .event))
    case .reminders: permission(EKEventStore.authorizationStatus(for: .reminder))
    case .contacts:
      switch CNContactStore.authorizationStatus(for: .contacts) {
      case .authorized: .granted
      case .notDetermined: .notDetermined
      case .restricted: .restricted
      case .denied, .limited: .denied
      @unknown default: .denied
      }
    }
  }

  private nonisolated static func permission(_ status: EKAuthorizationStatus) -> MacDataPermission {
    switch status {
    case .fullAccess: .granted
    case .notDetermined: .notDetermined
    case .restricted: .restricted
    case .denied, .writeOnly: .denied
    @unknown default: .denied
    }
  }

  /// Shows the macOS prompt the first time and waits for Alexandre's answer until `deadline`.
  func authorize(_ source: MacDataSource, until deadline: Date) async -> MacDataPermission {
    guard Self.permission(source) == .notDetermined else { return Self.permission(source) }
    switch source {
    case .calendar: events.requestFullAccessToEvents { _, _ in }
    case .reminders: events.requestFullAccessToReminders { _, _ in }
    case .contacts: Task { _ = try? await CNContactStore().requestAccess(for: .contacts) }
    }
    while Self.permission(source) == .notDetermined, Date.now < deadline, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(250))
    }
    // A store created before the grant does not see the data.
    if source != .contacts, Self.permission(source) == .granted { events = EKEventStore() }
    return Self.permission(source)
  }

  func collect(_ query: MacDataQuery, until deadline: Date) async throws -> JSONValue {
    switch query.source {
    case .calendar: try await calendar(query, until: deadline)
    case .reminders: try await reminders(query, until: deadline)
    case .contacts: try await contacts(query, until: deadline)
    case .status: throw MacDataFailure("invalid", source: "status", "status is answered by the app")
    }
  }

  // MARK: Calendar

  private struct Event: Encodable {
    let title: String
    let start: String
    let end: String
    let allDay: Bool
    let calendar: String
    var account: String?
    var location: String?
    var notes: String?
    var url: String?
    var attendees: [String]?
    var recurring: Bool?
    var canceled: Bool?
  }

  private struct Events: Encodable {
    let source = "calendar"
    let timeZone: String
    let from: String
    let to: String
    let availableCalendars: [String]
    let total: Int
    let events: [Event]
  }

  private func calendar(_ query: MacDataQuery, until deadline: Date) async throws -> JSONValue {
    try await require(.calendar, until: deadline)
    let period = try MacDataDates.events(from: query.from, to: query.to)
    let available = events.calendars(for: .event)
    let selected = try select(available, names: query.calendars, source: "calendar")
    let found = events.events(matching: events.predicateForEvents(withStart: period.start, end: period.end,
      calendars: selected))
      .filter { matches(query.query, [$0.title, $0.location, $0.notes]) }
      .sorted { ($0.startDate, $0.title ?? "") < ($1.startDate, $1.title ?? "") }
    return try JSONValue(encoding: Events(timeZone: TimeZone.current.identifier, from: MacDataDates.iso(period.start),
      to: MacDataDates.iso(period.end), availableCalendars: available.map(\.title).sorted(), total: found.count,
      events: found.prefix(query.limit ?? 50).map(Self.event)))
  }

  private static func event(_ event: EKEvent) -> Event {
    var item = Event(title: event.title ?? "",
      start: event.isAllDay ? MacDataDates.day(event.startDate) : MacDataDates.iso(event.startDate),
      end: event.isAllDay ? MacDataDates.day(event.endDate) : MacDataDates.iso(event.endDate),
      allDay: event.isAllDay, calendar: event.calendar?.title ?? "")
    item.account = event.calendar?.source?.title
    item.location = nonEmpty(event.location)
    item.notes = nonEmpty(event.notes).map { String($0.prefix(notesLimit)) }
    item.url = event.url?.absoluteString
    if let attendees = event.attendees, !attendees.isEmpty {
      item.attendees = attendees.prefix(20).map { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
    }
    if event.hasRecurrenceRules { item.recurring = true }
    if event.status == .canceled { item.canceled = true }
    return item
  }

  // MARK: Reminders

  private struct Reminder: Encodable, Sendable {
    let title: String
    let list: String
    let completed: Bool
    var due: String?
    var completedAt: String?
    var priority: String?
    var notes: String?
    var url: String?
    /// Ordering only, not sent.
    let dueDate: Date?
    let completionDate: Date?
    enum CodingKeys: String, CodingKey { case title, list, completed, due, completedAt, priority, notes, url }
  }

  private struct Reminders: Encodable {
    let source = "reminders"
    let timeZone: String
    let status: String
    let availableLists: [String]
    let total: Int
    let reminders: [Reminder]
  }

  private func reminders(_ query: MacDataQuery, until deadline: Date) async throws -> JSONValue {
    try await require(.reminders, until: deadline)
    let status = query.status ?? "pending"
    let start = try query.from.map { try MacDataDates.parse($0, end: false) }
    let end = try query.to.map { try MacDataDates.parse($0, end: true) }
    if let start, let end { try MacDataDates.validate(start, end, source: "reminders") }
    let available = events.calendars(for: .reminder)
    let selected = try select(available, names: query.lists, source: "reminders")
    var found: [Reminder] = []
    if status != "completed" {
      found += await fetch(events.predicateForIncompleteReminders(withDueDateStarting: start, ending: end,
        calendars: selected))
    }
    if status != "pending" {
      found += await fetch(events.predicateForCompletedReminders(
        withCompletionDateStarting: start ?? Date.now.addingTimeInterval(-30 * 86_400), ending: end ?? .now,
        calendars: selected))
    }
    let items = found.filter { matches(query.query, [$0.title, $0.notes]) }.sorted(by: Self.order)
    return try JSONValue(encoding: Reminders(timeZone: TimeZone.current.identifier, status: status,
      availableLists: available.map(\.title).sorted(), total: items.count,
      reminders: Array(items.prefix(query.limit ?? 50))))
  }

  /// EventKit answers on its own queue; the reminders become plain values there.
  private func fetch(_ predicate: NSPredicate) async -> [Reminder] {
    await withCheckedContinuation { continuation in
      events.fetchReminders(matching: predicate) { reminders in
        continuation.resume(returning: (reminders ?? []).map(Self.reminder))
      }
    }
  }

  private nonisolated static func reminder(_ reminder: EKReminder) -> Reminder {
    let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    let priority: String? = switch reminder.priority {
    case 1...4: "high"
    case 5: "medium"
    case 6...9: "low"
    default: nil
    }
    return Reminder(title: reminder.title ?? "", list: reminder.calendar?.title ?? "", completed: reminder.isCompleted,
      due: due.map { reminder.dueDateComponents?.hour == nil ? MacDataDates.day($0) : MacDataDates.iso($0) },
      completedAt: reminder.completionDate.map { MacDataDates.iso($0) }, priority: priority,
      notes: nonEmpty(reminder.notes).map { String($0.prefix(notesLimit)) }, url: reminder.url?.absoluteString,
      dueDate: due, completionDate: reminder.completionDate)
  }

  /// Pending first by due date (undated last), then completed from the most recent.
  private static func order(_ a: Reminder, _ b: Reminder) -> Bool {
    if a.completed != b.completed { return !a.completed }
    if a.completed { return (a.completionDate ?? .distantPast) > (b.completionDate ?? .distantPast) }
    return (a.dueDate ?? .distantFuture, a.title) < (b.dueDate ?? .distantFuture, b.title)
  }

  // MARK: Contacts

  private struct Labeled: Encodable {
    let label: String
    let value: String
  }

  private struct Contact: Encodable {
    let name: String
    let phones: [Labeled]
    let emails: [Labeled]
    var nickname: String?
    var organization: String?
    var jobTitle: String?
    var birthday: String?
    var addresses: [Labeled]?
  }

  private struct Contacts: Encodable {
    let source = "contacts"
    let timeZone: String
    let total: Int
    let contacts: [Contact]
  }

  private func contacts(_ query: MacDataQuery, until deadline: Date) async throws -> JSONValue {
    try await require(.contacts, until: deadline)
    guard let text = nonEmpty(query.query?.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw MacDataFailure("invalid", source: "contacts", "Contacts need a name, phone or e-mail query")
    }
    let digits = text.filter(\.isNumber)
    let predicate =
      text.contains("@")
      ? CNContact.predicateForContacts(matchingEmailAddress: text)
      : digits.count >= 4 && text.allSatisfy({ $0.isNumber || " +-().".contains($0) })
        ? CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: text))
        : CNContact.predicateForContacts(matchingName: text)
    let keys: [CNKeyDescriptor] =
      [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)] + [
        CNContactNicknameKey, CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey, CNContactBirthdayKey, CNContactPostalAddressesKey,
      ].map { $0 as CNKeyDescriptor }
    let found = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys)
    return try JSONValue(encoding: Contacts(timeZone: TimeZone.current.identifier, total: found.count,
      contacts: found.prefix(query.limit ?? 10).map(Self.contact)))
  }

  private static func contact(_ contact: CNContact) -> Contact {
    let label = { (value: String?) in value.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
    var item = Contact(name: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName,
      phones: contact.phoneNumbers.map { Labeled(label: label($0.label), value: $0.value.stringValue) },
      emails: contact.emailAddresses.map { Labeled(label: label($0.label), value: $0.value as String) })
    item.nickname = nonEmpty(contact.nickname)
    item.organization = nonEmpty(contact.organizationName)
    item.jobTitle = nonEmpty(contact.jobTitle)
    if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
      item.birthday = birthday.year.map { String(format: "%04d-%02d-%02d", $0, month, day) }
        ?? String(format: "--%02d-%02d", month, day)
    }
    let addresses = contact.postalAddresses.map {
      Labeled(label: label($0.label), value: CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)
        .replacingOccurrences(of: "\n", with: ", "))
    }
    if !addresses.isEmpty { item.addresses = addresses }
    return item
  }

  // MARK: Support

  private func require(_ source: MacDataSource, until deadline: Date) async throws {
    let permission = await authorize(source, until: deadline)
    guard permission != .granted else { return }
    throw MacDataFailure(permission.rawValue, source: source.rawValue,
      permission == .notDetermined ? "The macOS permission prompt was not answered" : "macOS \(permission.rawValue) access")
  }

  private func select(_ calendars: [EKCalendar], names: [String]?, source: String) throws -> [EKCalendar]? {
    guard let names, !names.isEmpty else { return nil }
    let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    let wanted = Set(names.map(fold))
    let selected = calendars.filter { wanted.contains(fold($0.title)) }
    guard !selected.isEmpty else {
      throw MacDataFailure("invalid", source: source,
        "None of \(names.joined(separator: ", ")) exists. Available: \(calendars.map(\.title).sorted().joined(separator: ", "))")
    }
    return selected
  }
}

private func matches(_ query: String?, _ fields: [String?]) -> Bool {
  guard let query = nonEmpty(query) else { return true }
  return fields.contains { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
}

private func nonEmpty(_ value: String?) -> String? {
  guard let value, !value.isEmpty else { return nil }
  return value
}
