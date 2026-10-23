import Foundation
import Testing

@testable import OpenCodeKit

private func usageTokens(input: Double = 25_000, output: Double = 5_000, reasoning: Double = 0,
                         read: Double = 320_000, write: Double = 30_000) -> TokenUsage {
  TokenUsage(input: input, output: output, reasoning: reasoning, cache: .init(read: read, write: write))
}

@Test func contextUsageUsesAllComponentsButCacheOnlyUsesInputSide() throws {
  let usage = try #require(ContextUsage(tokens: usageTokens(), limit: 1_000_000))
  #expect(usage.total == 380_000)
  #expect(usage.fraction == 0.38)
  #expect(usage.cacheHit == 320_000.0 / 375_000)
  #expect(usage.contextLabel == "Contexto 38%")
  #expect(usage.tokenLabel == "380k / 1M")
  #expect(usage.cacheLabel == "Cache 85%")
  #expect(usage.accessibilityLabel == "Contexto 38 por cento, 380 mil de 1 milhão de tokens, cache 85 por cento")
}

@Test(arguments: [0.0, -1, Double.infinity]) func contextUsageUnknownLimitsRetainMeasuredTokens(_ limit: Double) throws {
  let usage = try #require(ContextUsage(tokens: usageTokens(), limit: limit))
  #expect(usage.fraction == nil)
  #expect(usage.contextLabel == "Contexto")
  #expect(usage.tokenLabel == "380k tokens")
  #expect(!usage.warning)
  #expect(ContextUsage(tokens: nil, limit: limit) == nil)
}

@Test func contextUsageZeroCacheAndMissingMeasurementsStayUnknown() throws {
  #expect(ContextUsage(tokens: nil, limit: 1_000_000) == nil)
  #expect(ContextUsage.cacheHit(nil) == nil)
  let usage = try #require(ContextUsage(tokens: usageTokens(input: 0, output: 10, read: 0, write: 0), limit: nil))
  #expect(usage.cacheHit == nil)
  #expect(usage.cacheLabel == "Cache —")
  #expect(usage.accessibilityLabel.contains("cache indisponível"))
  #expect(usage.contextAccessibilityLabel == "Contexto 10 tokens")
  #expect(ContextUsage.cacheHit(usageTokens(input: 100, read: 0, write: 100)) == 0)
  #expect(ContextUsage.cacheHit(usageTokens(input: 0, read: 100, write: 0)) == 1)
}

@Test func contextUsageVoiceOverKeepsExactCapacityAndCurrencyKeepsTinyCosts() throws {
  let usage = try #require(ContextUsage(tokens: usageTokens(input: 25_000, output: 14_000, read: 350_000, write: 10_000), limit: 1_050_000))
  #expect(usage.accessibilityLabel == "Contexto 38 por cento, 399 mil de 1 milhão e 50 mil de tokens, cache 91 por cento")
  #expect(ContextUsage.money(9.18).contains("9,18"))
  #expect(ContextUsage.money(0.000123).contains("0,000123"))
}

@Test(arguments: [(800_000.0, false), (800_001, true), (1_500_000, true)])
func contextUsageWarningUsesUnroundedFractionAndOnlyClampsDrawing(total: Double, warning: Bool) throws {
  let usage = try #require(ContextUsage(tokens: usageTokens(input: total, output: 0, read: 0, write: 0), limit: 1_000_000))
  #expect(usage.warning == warning)
  #expect(usage.total == total)
  #expect(usage.drawnFraction == min(1, total / 1_000_000))
}

@Test(arguments: [(0.0, "0"), (999, "999"), (1_000, "1k"), (1_200, "1,2k"), (380_000, "380k"),
  (999_999, "1M"), (1_000_000, "1M"), (1_200_000, "1,2M"), (1_050_000, "1,1M")])
func contextUsageAbbreviationsArePortuguese(value: Double, expected: String) {
  #expect(ContextUsage.compact(value) == expected)
}

@Test func contextUsageKeepsLatestMeasurementAcrossUnmeasuredStreamingAndMatchesProvider() throws {
  var measured = ConversationMessage(id: "measured", type: "assistant", time: .init(created: 1))
  measured.tokens = usageTokens()
  measured.model = ModelReference(id: "same", providerID: "correct")
  let final = ConversationMessage(id: "final", type: "assistant", time: .init(created: 2, completed: 3))
  let user = ConversationMessage(id: "user", type: "user", time: .init(created: 4))
  let later = ConversationMessage(id: "later", type: "assistant", time: .init(created: 5, completed: 6))
  #expect(ConversationProjection.latestMeasurement([measured, final])?.id == "measured")
  #expect(ConversationProjection.latestMeasurement([measured, final, user, later])?.id == "measured")
  var terminal = measured
  terminal.id = "terminal"
  terminal.time.completed = 3
  #expect(ConversationProjection.latestMeasurement([measured, final, terminal, user, later])?.id == "terminal")
  let streaming = ConversationMessage(id: "streaming", type: "assistant", time: .init(created: 4))
  #expect(ConversationProjection.latestMeasurement([measured, final, streaming])?.id == "measured")
  #expect(ConversationProjection.latestMeasurement([user, streaming]) == nil)
  #expect(ConversationProjection.latestMeasurement([]) == nil)
  let models = try JSONDecoder().decode([ModelInfo].self, from: Data("""
    [{"id":"same","providerID":"wrong","name":"A","limit":{"context":1}},
    {"id":"same","providerID":"correct","name":"B","limit":{"context":1000000}}]
    """.utf8))
  #expect(ContextUsage.limit(measured.model, models: models) == 1_000_000)
}

@MainActor @Test func contextUsageFormattingCacheReusesVersionsAndInvalidatesTokensAndLimits() throws {
  let cache = ContextUsageCache()
  _ = cache.value(id: "one", tokens: usageTokens(), model: nil, models: [])
  _ = cache.value(id: "one", tokens: usageTokens(), model: nil, models: [])
  #expect(cache.formattedCount == 1)
  _ = cache.value(id: "one", tokens: usageTokens(output: 10_000), model: nil, models: [])
  #expect(cache.formattedCount == 2)
  let model = try JSONDecoder().decode(ModelInfo.self, from: Data(
    #"{"id":"m","providerID":"p","name":"M","limit":{"context":1000000}}"#.utf8))
  _ = cache.value(id: "one", tokens: usageTokens(), model: .init(id: "m", providerID: "p"), models: [model])
  #expect(cache.formattedCount == 3)
  for index in 0..<513 {
    _ = cache.value(id: "eviction-\(index)", tokens: usageTokens(), model: nil, models: [])
  }
  let count = cache.formattedCount
  _ = cache.value(id: "one", tokens: usageTokens(), model: nil, models: [])
  #expect(cache.formattedCount == count + 1)
}

@Test func familyPageRetainsLastStepContextSeparatelyFromSessionTotals() throws {
  let page = try JSONDecoder().decode(FamilyPage.self, from: Data("""
    {"data":[{"id":"child","projectID":"global","location":{"directory":"/sandbox"},
    "time":{"created":1,"updated":2},"tokens":{"input":999,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},
    "context":{"id":"step","model":{"id":"m","providerID":"p"},"tokens":{"input":1,"output":2,"reasoning":3,"cache":{"read":4,"write":5}}}}]}
    """.utf8))
  #expect(page.data.first?.tokens?.total == 999)
  #expect(page.data.first?.context?.tokens.total == 15)
  #expect(page.data.first?.context?.model.id == "m")
}
