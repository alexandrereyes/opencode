import CoreLocation
import MapKit
import OpenCodeKit
import Synchronization
import UIKit

/// "When In Use" location: a fresh fix and its address only while the app is in the foreground. In the background
/// (a voice call with the screen off) iOS gives no new fix, so the answer carries the last known position instead.
@MainActor final class DeviceLocationCollector {
  private let manager = CLLocationManager()

  var authorization: DeviceAuthorization {
    guard CLLocationManager.locationServicesEnabled() else { return .unavailable }
    return switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: manager.accuracyAuthorization == .reducedAccuracy ? .limited : .authorized
    case .denied: .denied
    case .restricted: .restricted
    default: .notDetermined
    }
  }

  func requestAuthorization() async -> DeviceAuthorization {
    guard manager.authorizationStatus == .notDetermined else { return authorization }
    manager.requestWhenInUseAuthorization()
    // The prompt has no completion; follow the status until Alexandre answers it (at most a minute).
    for _ in 0..<240 where manager.authorizationStatus == .notDetermined {
      try? await Task.sleep(for: .milliseconds(250))
    }
    return authorization
  }

  private struct Address: Encodable, Sendable { let full: String?; let short: String?; let city: String?; let region: String? }

  func collect() async -> DeviceAnswer {
    struct Position: Encodable {
      let latitude: Double
      let longitude: Double
      let accuracyMeters: Double
      let altitudeMeters: Double?
      let speedKmh: Double?
      let timestamp: Date
      let ageSeconds: Int
      let current: Bool
      let address: Address?
    }
    switch authorization {
    case .denied, .restricted: return .failure(.denied, "Location access is off for OpenCode in iOS Settings.")
    case .notDetermined: return .failure(.denied, "Location permission has not been granted yet (Você → Dados do iPhone).")
    case .unavailable: return .failure(.unavailable, "Location Services are turned off on the iPhone.")
    default: break
    }
    let foreground = UIApplication.shared.applicationState == .active
    let fix = foreground ? await current() : nil
    guard let location = fix ?? manager.location else {
      return .failure(.unavailable, foreground
        ? "No location fix within the time limit."
        : "The app is in the background: with “While Using” permission iOS gives no current location, and there is no last known position.")
    }
    let address = await address(location)
    return .ok(Position(
      latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
      accuracyMeters: location.horizontalAccuracy.rounded(),
      altitudeMeters: location.verticalAccuracy > 0 ? location.altitude.rounded() : nil,
      speedKmh: location.speed >= 0 ? (location.speed * 3.6 * 10).rounded() / 10 : nil,
      timestamp: location.timestamp, ageSeconds: Int(-location.timestamp.timeIntervalSinceNow),
      current: fix != nil, address: address),
      note: fix == nil
        ? "The app is in the background: with “While Using” permission iOS gives no current location; this is the last known position."
        : nil)
  }

  /// The first fix younger than 15 seconds; at the 3-second limit, the best older fix seen so far.
  private func current() async -> CLLocation? {
    let fallback = Mutex<CLLocation?>(nil)
    let fresh = await withTaskGroup(of: CLLocation?.self) { group in
      group.addTask {
        do {
          for try await update in CLLocationUpdate.liveUpdates() {
            guard let location = update.location, location.horizontalAccuracy >= 0 else { continue }
            if -location.timestamp.timeIntervalSinceNow < 15 { return location }
            fallback.withLock { $0 = location }
          }
        } catch {}
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(3))
        return nil
      }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }
    return fresh ?? fallback.withLock { $0 }
  }

  private func address(_ location: CLLocation) async -> Address? {
    await withTaskGroup(of: Address?.self) { group in
      group.addTask { await Self.geocode(location) }
      group.addTask {
        try? await Task.sleep(for: .seconds(1.5))
        return nil
      }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }
  }

  private static func geocode(_ location: CLLocation) async -> Address? {
    guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
    request.preferredLocale = Locale(identifier: "pt_BR")
    guard let item = try? await request.mapItems.first else { return nil }
    return Address(full: item.address?.fullAddress, short: item.address?.shortAddress,
      city: item.addressRepresentations?.cityWithContext, region: item.addressRepresentations?.regionName)
  }
}
