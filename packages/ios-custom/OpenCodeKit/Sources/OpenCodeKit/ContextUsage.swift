import Foundation

public struct SessionContext: Codable, Sendable, Hashable {
  public let id: String
  public let tokens: TokenUsage
  public let model: ModelReference
}

public struct ContextUsage: Sendable, Equatable {
  public let total: Double
  public let limit: Double?
  public let fraction: Double?
  public let cacheHit: Double?
  public let contextLabel: String
  public let shortContextLabel: String
  public let tokenLabel: String
  public let cacheLabel: String
  public let totalLabel: String
  public let cacheReadLabel: String
  public let cacheWriteLabel: String
  public let cachePercentLabel: String
  public let contextAccessibilityLabel: String
  public let accessibilityLabel: String
  public var warning: Bool { (fraction ?? 0) > 0.8 }
  public var drawnFraction: Double { min(1, max(0, fraction ?? 0)) }

  public init?(tokens: TokenUsage?, limit: Double?) {
    guard let tokens else { return nil }
    let total = tokens.total
    self.total = total
    self.limit = limit.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
    fraction = self.limit.map { total / $0 }
    cacheHit = Self.cacheHit(tokens)
    contextLabel = fraction.map { "Contexto \(Self.percent($0))" } ?? "Contexto"
    shortContextLabel = fraction == nil ? "Contexto \(Self.compact(total)) tokens" : contextLabel
    tokenLabel = Self.compact(total) + (self.limit.map { " / \(Self.compact($0))" } ?? " tokens")
    cacheLabel = "Cache " + (cacheHit.map(Self.percent) ?? "—")
    totalLabel = Self.compact(total)
    cacheReadLabel = Self.compact(tokens.cache.read)
    cacheWriteLabel = Self.compact(tokens.cache.write)
    cachePercentLabel = cacheHit.map(Self.percent) ?? "—"
    contextAccessibilityLabel = "Contexto " + (fraction.map { "\(Self.integer($0 * 100)) por cento, " } ?? "")
      + Self.spoken(total) + (self.limit.map { " de \(Self.spoken($0)) de tokens" } ?? " tokens")
    accessibilityLabel = contextAccessibilityLabel + ", "
      + (cacheHit.map { "cache \(Self.integer($0 * 100)) por cento" } ?? "cache indisponível")
  }

  public static func limit(_ reference: ModelReference?, models: [ModelInfo]) -> Double? {
    models.first { $0.id == reference?.id && $0.providerID == reference?.providerID }?.limit.context
  }

  public static func cacheHit(_ tokens: TokenUsage?) -> Double? {
    guard let tokens else { return nil }
    let denominator = tokens.input + tokens.cache.read + tokens.cache.write
    return denominator > 0 ? tokens.cache.read / denominator : nil
  }

  public static func percent(_ fraction: Double) -> String { integer(fraction * 100) + "%" }

  public static func compact(_ value: Double) -> String {
    let unit = value >= 1_000_000 ? 1_000_000.0 : value >= 1_000 ? 1_000.0 : 1.0
    let scaled = (value / unit * 10).rounded() / 10
    if unit == 1_000, scaled >= 1_000 { return compact(1_000_000) }
    return scaled.formatted(.number.locale(Locale(identifier: "pt_BR"))
      .grouping(.never).precision(.fractionLength(0...1)))
      + (unit == 1_000_000 ? "M" : unit == 1_000 ? "k" : "")
  }

  public static func spoken(_ value: Double) -> String {
    if value >= 1_000_000 {
      let millions = (value / 1_000_000).rounded(.down)
      let remainder = value.truncatingRemainder(dividingBy: 1_000_000)
      return integer(millions) + (millions == 1 ? " milhão" : " milhões")
        + (remainder > 0 ? " e " + spoken(remainder) : "")
    }
    if value >= 1_000, value.truncatingRemainder(dividingBy: 1_000) == 0 {
      return integer(value / 1_000) + " mil"
    }
    return integer(value)
  }

  public static func money(_ value: Double?) -> String {
    value.map { $0.formatted(.currency(code: "USD").locale(Locale(identifier: "pt_BR"))
      .precision(.fractionLength($0 > 0 && $0 < 0.01 ? 2...6 : 2...2))) } ?? "—"
  }

  private static func integer(_ value: Double) -> String {
    value.rounded().formatted(.number.locale(Locale(identifier: "pt_BR")).precision(.fractionLength(0)))
  }
}

/// Formatting is keyed by the measured facts, not the changing text/tool payload.
@MainActor public final class ContextUsageCache {
  private struct Key: Hashable {
    let id: String
    let tokens: TokenUsage
    let limit: Double?
  }
  private var values: [Key: ContextUsage] = [:]
  private var order: [Key] = []
  public private(set) var formattedCount = 0
  public init() {}

  public func value(id: String, tokens: TokenUsage?, model: ModelReference?, models: [ModelInfo]) -> ContextUsage? {
    value(id: id, tokens: tokens, limit: ContextUsage.limit(model, models: models))
  }

  public func value(id: String, tokens: TokenUsage?, limit: Double?) -> ContextUsage? {
    guard let tokens else { return nil }
    let key = Key(id: id, tokens: tokens, limit: limit)
    if let value = values[key] { return value }
    guard let value = ContextUsage(tokens: tokens, limit: key.limit) else { return nil }
    values[key] = value
    order.append(key)
    formattedCount += 1
    if order.count > 512 { values.removeValue(forKey: order.removeFirst()) }
    return value
  }
}

extension ConversationProjection {
  /// Unmeasured streaming steps keep the preceding measurement visible. Like the TUI and web
  /// (`lastAssistantWithUsage`), a completed compaction ends it: nothing is measured until the next step.
  public static func latestMeasurement(_ messages: [ConversationMessage]) -> ConversationMessage? {
    let start = messages.lastIndex { $0.type == .compaction && $0.status == "completed" }.map { $0 + 1 } ?? 0
    return messages[start...].last { $0.type == .assistant && $0.tokens != nil }
  }
}
