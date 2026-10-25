import CoreMotion
import Network
import OpenCodeKit
import UIKit

/// One collector per `DeviceSource`. Each returns source-specific JSON and explains partial answers in `note`.
@MainActor final class DeviceCollectors {
  let location = DeviceLocationCollector()
  let health = DeviceHealthCollector()
  let photos = DevicePhotosCollector()
  private let motion = DeviceMotionCollector()

  static var modelIdentifier: String {
    var system = utsname()
    uname(&system)
    return withUnsafeBytes(of: &system.machine) { buffer in
      String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  func authorization(_ source: DeviceSource) async -> DeviceAuthorization {
    switch source {
    case .device, .network: .authorized
    case .location: location.authorization
    case .health: await health.authorization()
    case .motion: motion.authorization
    case .photos: photos.authorization
    }
  }

  func requestAuthorization(_ source: DeviceSource) async -> DeviceAuthorization {
    switch source {
    case .device, .network: return .authorized
    case .location: return await location.requestAuthorization()
    case .health: return await health.requestAuthorization()
    case .motion: return await motion.requestAuthorization()
    case .photos: return await photos.requestAuthorization()
    }
  }

  func collect(_ query: DeviceQuery) async -> DeviceAnswer {
    switch query.source {
    case .device: return device()
    case .network: return await network()
    case .location: return await location.collect()
    case .health: return await health.collect(query)
    case .motion: return await motion.collect(query)
    case .photos: return await photos.collect(query)
    }
  }

  private func device() -> DeviceAnswer {
    struct Battery: Encodable { let percent: Int?; let state: String }
    struct Storage: Encodable { let availableGB: Double; let totalGB: Double }
    struct Info: Encodable {
      let name: String
      let model: String
      let system: String
      let battery: Battery
      let lowPowerMode: Bool
      let thermalState: String
      let storage: Storage?
      let locked: Bool
      let appState: String
    }
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let state = switch device.batteryState {
    case .charging: "charging"
    case .full: "full"
    case .unplugged: "unplugged"
    default: "unknown"
    }
    let thermal = switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
    let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
    ])
    let storage = values.flatMap { values -> Storage? in
      guard let available = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity
      else { return nil }
      return Storage(availableGB: gigabytes(Double(available)), totalGB: gigabytes(Double(total)))
    }
    let application = UIApplication.shared
    return .ok(Info(
      name: device.name, model: Self.modelIdentifier, system: "iOS " + device.systemVersion,
      battery: Battery(percent: device.batteryLevel < 0 ? nil : Int((device.batteryLevel * 100).rounded()), state: state),
      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: thermal, storage: storage,
      locked: !application.isProtectedDataAvailable,
      appState: application.applicationState == .active ? "foreground" : "background"))
  }

  private func network() async -> DeviceAnswer {
    struct Network: Encodable {
      let status: String
      let interfaces: [String]
      let expensive: Bool
      let constrained: Bool
      let ipv4: Bool
      let ipv6: Bool
    }
    let monitor = NWPathMonitor()
    for await path in monitor {
      let interfaces: [(NWInterface.InterfaceType, String)] = [
        (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.other, "other"),
      ]
      let status = switch path.status {
      case .satisfied: "connected"
      case .requiresConnection: "requiresConnection"
      default: "disconnected"
      }
      return .ok(Network(status: status, interfaces: interfaces.filter { path.usesInterfaceType($0.0) }.map(\.1),
        expensive: path.isExpensive, constrained: path.isConstrained, ipv4: path.supportsIPv4, ipv6: path.supportsIPv6))
    }
    return .failure(.error, "The network monitor ended without a path.")
  }

  private func gigabytes(_ bytes: Double) -> Double { (bytes / 1_000_000_000 * 10).rounded() / 10 }
}

@MainActor private final class DeviceMotionCollector {
  private let pedometer = CMPedometer()
  private let activity = CMMotionActivityManager()

  var authorization: DeviceAuthorization {
    guard CMPedometer.isStepCountingAvailable() else { return .unavailable }
    return switch CMPedometer.authorizationStatus() {
    case .authorized: .authorized
    case .denied: .denied
    case .restricted: .restricted
    default: .notDetermined
    }
  }

  /// CoreMotion has no request API: the first query shows the permission prompt.
  func requestAuthorization() async -> DeviceAuthorization {
    guard authorization == .notDetermined else { return authorization }
    _ = try? await steps(from: .now.addingTimeInterval(-60), to: .now)
    return authorization
  }

  func collect(_ query: DeviceQuery) async -> DeviceAnswer {
    struct Day: Encodable {
      let day: String
      let steps: Int?
      let distanceKm: Double?
      let floorsAscended: Int?
      let floorsDescended: Int?
      let activityMinutes: [String: Int]?
    }
    struct Motion: Encodable { let from: String; let to: String; let timeZone: String; let days: [Day] }
    switch authorization {
    case .unavailable: return .failure(.unavailable, "Motion data is not available on this device.")
    case .denied, .restricted: return .failure(.denied, "Motion & Fitness access is off in iOS Settings.")
    default: break
    }
    let calendar = Calendar.current
    guard let range = DeviceDayRange.resolve(from: query.from, to: query.to, maxDays: 8) else {
      return .failure(.error, "Invalid range: motion history covers only the last 7 days.")
    }
    let oldest = Date.now.addingTimeInterval(-7 * 86_400)
    var days: [Day] = []
    let activities = CMMotionActivityManager.isActivityAvailable() ? (try? await activities(from: max(range.start, oldest), to: range.end)) : nil
    let minutes = activities.map { DeviceMotion.minutes($0, end: range.end, calendar: calendar) }
    do {
      for label in range.days {
        guard let start = DeviceDayRange.resolve(from: label, to: label, maxDays: 1)?.start else { continue }
        let end = min(calendar.date(byAdding: .day, value: 1, to: start) ?? .now, .now)
        let data = end > oldest ? try await steps(from: max(start, oldest), to: end) : nil
        days.append(Day(day: label, steps: data?.steps, distanceKm: data?.distanceKm,
          floorsAscended: data?.floorsAscended, floorsDescended: data?.floorsDescended, activityMinutes: minutes?[label]))
      }
    } catch {
      return .failure(authorization == .denied ? .denied : .error, "Motion query failed: \(error.localizedDescription)")
    }
    return .ok(Motion(from: range.days.first ?? "", to: range.days.last ?? "", timeZone: calendar.timeZone.identifier, days: days),
      note: range.start < oldest ? "CoreMotion keeps only the last 7 days; older days have no data." : nil)
  }

  private struct Steps: Sendable { let steps: Int; let distanceKm: Double?; let floorsAscended: Int?; let floorsDescended: Int? }

  private func steps(from start: Date, to end: Date) async throws -> Steps? {
    try await withCheckedThrowingContinuation { continuation in
      // CoreMotion calls back on its own queue: the handler must not inherit main-actor isolation.
      pedometer.queryPedometerData(from: start, to: end) { @Sendable data, error in
        if let error { return continuation.resume(throwing: error) }
        continuation.resume(returning: data.map { data in
          Steps(steps: data.numberOfSteps.intValue, distanceKm: data.distance.map { ($0.doubleValue / 100).rounded() / 10 },
            floorsAscended: data.floorsAscended?.intValue, floorsDescended: data.floorsDescended?.intValue)
        })
      }
    }
  }

  private func activities(from start: Date, to end: Date) async throws -> [DeviceMotion.Activity] {
    try await withCheckedThrowingContinuation { continuation in
      activity.queryActivityStarting(from: start, to: end, to: .main) { @Sendable values, error in
        if let error { return continuation.resume(throwing: error) }
        continuation.resume(returning: (values ?? []).map { value in
          let kind = value.running ? "running" : value.cycling ? "cycling" : value.automotive ? "automotive"
            : value.walking ? "walking" : value.stationary ? "stationary" : "unknown"
          return DeviceMotion.Activity(start: value.startDate, kind: kind)
        })
      }
    }
  }
}
