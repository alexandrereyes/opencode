import HealthKit
import OpenCodeKit
import UIKit

/// Read-only HealthKit: daily aggregates through statistics collection queries (sources merged, without double
/// counting iPhone and Watch), sleep and workouts from samples. HealthKit is unreadable while the iPhone is
/// locked, so a daily summary of the last 90 days, protected until first unlock, answers then.
@MainActor final class DeviceHealthCollector {
  private let store = HKHealthStore()
  private var refreshing: Task<Void, Never>?
  private var refreshedAt: Date?
  private static let days = 90

  private static let readTypes: Set<HKObjectType> = [
    HKCategoryType(.sleepAnalysis), HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned),
    HKQuantityType(.restingHeartRate), HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.bodyMass),
    HKObjectType.workoutType(), HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling),
    HKQuantityType(.distanceSwimming),
  ]

  /// iOS never reveals whether reading was denied: after the prompt the state is only "requested".
  func authorization() async -> DeviceAuthorization {
    guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
    let status = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
    return status == .unnecessary ? .requested : .notDetermined
  }

  func requestAuthorization() async -> DeviceAuthorization {
    guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
    try? await store.requestAuthorization(toShare: [], read: Self.readTypes)
    return await authorization()
  }

  func collect(_ query: DeviceQuery) async -> DeviceAnswer {
    guard HKHealthStore.isHealthDataAvailable() else { return .failure(.unavailable, "HealthKit is not available.") }
    guard let range = DeviceDayRange.resolve(from: query.from, to: query.to, maxDays: Self.days) else {
      return .failure(.error, "Invalid range: health queries cover at most \(Self.days) days (from/to as YYYY-MM-DD).")
    }
    let metrics = Set(query.metrics ?? DeviceMetric.allCases)
    let samples = query.granularity == .sample
    guard UIApplication.shared.isProtectedDataAvailable else { return cached(range, metrics) }
    do {
      let (summary, truncated) = try await read(range, metrics: metrics, samples: samples)
      return .ok(summary, note: "Read-only HealthKit data. Queries return no data for types iOS was not allowed to share.",
        truncated: truncated ? true : nil)
    } catch let error as HKError where error.code == .errorDatabaseInaccessible {
      return cached(range, metrics)
    } catch {
      return .failure(.error, "HealthKit query failed: \(error.localizedDescription)")
    }
  }

  /// Rebuilds the locked-iPhone summary at most every 30 minutes, or right away when the source was just enabled.
  func refreshCache(force: Bool) {
    guard refreshing == nil, force || (refreshedAt.map { Date.now.timeIntervalSince($0) > 1_800 } ?? true),
      UIApplication.shared.isProtectedDataAvailable,
      let range = DeviceDayRange.resolve(from: nil, to: nil, defaultDays: Self.days, maxDays: Self.days)
    else { return }
    refreshing = Task {
      defer { refreshing = nil }
      guard var (summary, _) = try? await read(range, metrics: Set(DeviceMetric.allCases), samples: false) else { return }
      summary.cachedAt = .now
      guard let data = try? summary.encoded() else { return }
      do {
        try FileManager.default.createDirectory(at: Self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.cache, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        refreshedAt = .now
      } catch { DeviceAgent.log.error("health cache write failed: \(error.localizedDescription, privacy: .public)") }
    }
  }

  #if DEBUG
  func cachedAnswer(_ query: DeviceQuery) -> DeviceAnswer {
    guard let range = DeviceDayRange.resolve(from: query.from, to: query.to, maxDays: Self.days) else {
      return .failure(.error, "Invalid range")
    }
    return cached(range, Set(query.metrics ?? DeviceMetric.allCases))
  }
  #endif

  private static var cache: URL {
    URL.applicationSupportDirectory.appending(path: "OpenCode/DeviceData/health-summary.json")
  }

  private func cached(_ range: DeviceDayRange, _ metrics: Set<DeviceMetric>) -> DeviceAnswer {
    guard let data = try? Data(contentsOf: Self.cache), let summary = try? DeviceHealth.Summary.decode(data),
      let cachedAt = summary.cachedAt
    else {
      return .failure(.locked, "The iPhone is locked: HealthKit cannot be read and there is no cached summary yet.")
    }
    let stamp = cachedAt.formatted(.iso8601)
    return .ok(summary.filtered(days: range.days, metrics: metrics), note:
      "The iPhone is locked: answered from the daily summary cached at \(stamp). Per-sample detail and anything newer are unavailable until it is unlocked.")
  }

  private func read(_ range: DeviceDayRange, metrics: Set<DeviceMetric>, samples: Bool) async throws
    -> (DeviceHealth.Summary, Bool)
  {
    var summary = DeviceHealth.Summary(from: range.days.first ?? "", to: range.days.last ?? "",
      timeZone: TimeZone.current.identifier)
    var truncated = false
    if metrics.contains(.steps) { summary.steps = try await daily(.stepCount, .cumulativeSum, .count(), range) }
    if metrics.contains(.activeEnergy) {
      summary.activeEnergyKcal = try await daily(.activeEnergyBurned, .cumulativeSum, .kilocalorie(), range)
    }
    let bpm = HKUnit.count().unitDivided(by: .minute())
    if metrics.contains(.restingHeartRate) {
      summary.restingHeartRateBpm = try await daily(.restingHeartRate, [.discreteAverage, .discreteMin, .discreteMax], bpm, range)
    }
    if metrics.contains(.hrv) {
      summary.hrvMs = try await daily(.heartRateVariabilitySDNN, [.discreteAverage, .discreteMin, .discreteMax],
        .secondUnit(with: .milli), range)
    }
    if metrics.contains(.weight) {
      summary.weightKg = try await daily(.bodyMass, .discreteAverage, .gramUnit(with: .kilo), range)
    }
    if metrics.contains(.sleep) {
      // A night ending on the first day starts the evening before.
      let raw = try await sleep(from: range.start.addingTimeInterval(-12 * 3_600), to: range.end)
      summary.sleep = DeviceHealth.nights(raw).filter { range.days.contains($0.day) }
      if samples {
        let kept = raw.filter { sample in summary.sleep?.contains { $0.start <= sample.start && sample.end <= $0.end } == true }
        summary.sleepSamples = kept.prefix(400).map { .init(start: $0.start, end: $0.end, stage: $0.stage, source: $0.source) }
        truncated = truncated || kept.count > 400
      }
    }
    if metrics.contains(.workouts) {
      let found = try await workouts(range)
      summary.workouts = Array(found.prefix(100))
      truncated = truncated || found.count > 100
    }
    return (summary, truncated)
  }

  private func daily(_ identifier: HKQuantityTypeIdentifier, _ options: HKStatisticsOptions, _ unit: HKUnit,
    _ range: DeviceDayRange) async throws -> [DeviceHealth.Summary.Value]
  {
    let type = HKQuantityType(identifier)
    let descriptor = HKStatisticsCollectionQueryDescriptor(
      predicate: .quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: range.start, end: range.end)),
      options: options, anchorDate: range.start, intervalComponents: DateComponents(day: 1))
    let collection = try await descriptor.result(for: store)
    var values: [DeviceHealth.Summary.Value] = []
    collection.enumerateStatistics(from: range.start, to: range.end) { statistics, _ in
      let value = options.contains(.cumulativeSum)
        ? statistics.sumQuantity()?.doubleValue(for: unit)
        : statistics.averageQuantity()?.doubleValue(for: unit)
      guard let value else { return }
      let round = { (number: Double) in (number * 10).rounded() / 10 }
      values.append(.init(day: DeviceDayRange.label(statistics.startDate), value: round(value),
        min: statistics.minimumQuantity().map { round($0.doubleValue(for: unit)) },
        max: statistics.maximumQuantity().map { round($0.doubleValue(for: unit)) }))
    }
    return values
  }

  private func sleep(from start: Date, to end: Date) async throws -> [DeviceHealth.SleepSample] {
    let descriptor = HKSampleQueryDescriptor(
      predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
        predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
      sortDescriptors: [SortDescriptor(\.startDate)])
    return try await descriptor.result(for: store).compactMap { sample in
      let stage: String? = switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
      case .inBed: "inBed"
      case .awake: "awake"
      case .asleepCore: "asleepCore"
      case .asleepDeep: "asleepDeep"
      case .asleepREM: "asleepREM"
      case .asleepUnspecified: "asleepUnspecified"
      default: nil
      }
      return stage.map { DeviceHealth.SleepSample(start: sample.startDate, end: sample.endDate, stage: $0,
        source: sample.sourceRevision.source.name) }
    }
  }

  private func workouts(_ range: DeviceDayRange) async throws -> [DeviceHealth.Summary.Workout] {
    let descriptor = HKSampleQueryDescriptor(
      predicates: [.workout(HKQuery.predicateForSamples(withStart: range.start, end: range.end))],
      sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 101)
    return try await descriptor.result(for: store).map { workout in
      let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
      let distance = [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
        .lazy.compactMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)) }
        .first
      return .init(day: DeviceDayRange.label(workout.startDate), start: workout.startDate, end: workout.endDate,
        activity: Self.activity(workout.workoutActivityType), minutes: Int((workout.duration / 60).rounded()),
        energyKcal: energy.map { $0.rounded() }, distanceKm: distance.map { ($0 * 100).rounded() / 100 },
        source: workout.sourceRevision.source.name)
    }
  }

  private static func activity(_ type: HKWorkoutActivityType) -> String {
    switch type {
    case .running: "running"
    case .walking: "walking"
    case .hiking: "hiking"
    case .cycling: "cycling"
    case .swimming: "swimming"
    case .traditionalStrengthTraining: "strengthTraining"
    case .functionalStrengthTraining: "functionalStrengthTraining"
    case .highIntensityIntervalTraining: "hiit"
    case .coreTraining: "coreTraining"
    case .yoga: "yoga"
    case .pilates: "pilates"
    case .elliptical: "elliptical"
    case .rowing: "rowing"
    case .stairClimbing: "stairClimbing"
    case .dance, .cardioDance, .socialDance: "dance"
    case .soccer: "soccer"
    case .tennis: "tennis"
    case .mixedCardio: "mixedCardio"
    case .flexibility: "flexibility"
    case .cooldown: "cooldown"
    case .other: "other"
    default: "activity\(type.rawValue)"
    }
  }
}
