import Foundation
import Testing
@testable import OpenCodeKit

private func paletteModel(_ id: String, _ name: String, provider: String = "p", variants: [String] = []) throws -> ModelInfo {
  try JSONDecoder().decode(ModelInfo.self, from: JSONEncoder().encode(JSONValue.object([
    "id": .string(id), "name": .string(name), "providerID": .string(provider),
    "limit": .object(["context": .number(1000000)]),
    "variants": .array(variants.map { .object(["id": .string($0)]) }),
  ])))
}

private func palettePreferences(_ models: [ModelInfo], favorites: [String] = []) throws -> Preferences.Models {
  try JSONDecoder().decode(Preferences.Models.self, from: JSONEncoder().encode(JSONValue.object([
    "user": .array(models.map { .object(["providerID": .string($0.providerID), "modelID": .string($0.id), "visibility": .string("show")]) }),
    "favorites": .array(models.filter { favorites.contains($0.identity) }.map {
      .object(["providerID": .string($0.providerID), "modelID": .string($0.id)])
    }), "variant": .object([:]),
  ])))
}

@Test func paletteRankingHighlightsAndVisibility() throws {
  let visible = try [paletteModel("inside", "Materra"), paletteModel("word", "GPT Térra"),
    paletteModel("prefix", "Terra Fast"), paletteModel("metadata", "Outro", provider: "Terra provider")]
  let hidden = try paletteModel("hidden", "Terra invisível")
  let rows = ModelPalette.rows(models: visible + [hidden], preferences: try palettePreferences(visible), providers: [],
    favorites: ["p/inside"], recent: [], query: "terra")
  #expect(rows.map(\.model.id) == ["prefix", "word", "inside", "metadata"])
  #expect(rows[1].matches.map { String(rows[1].model.name[$0]) } == ["Térra"])
  #expect(ModelPalette.matches("Térra terra", query: "TERRA").count == 2)
  #expect(ModelPalette.rows(models: visible, preferences: nil, providers: [], favorites: [], recent: [], query: "").isEmpty)
}

@Test func paletteEmptyGroupsFavoritesThenRecentThenProviders() throws {
  let models = try [paletteModel("z", "Zeta", provider: "z"), paletteModel("r", "Recent"),
    paletteModel("f", "Favorite"), paletteModel("a", "Alpha")]
  let preferences = try palettePreferences(models, favorites: ["p/f"])
  let favorites = Set(models.filter { ConversationProjection.favorite($0, preferences: preferences) }.map(\.identity))
  let rows = ModelPalette.rows(models: models, preferences: preferences,
    providers: [.init(id: "p", name: "Provider P"), .init(id: "z", name: "Provider Z")], favorites: favorites,
    recent: [.init(id: "r", providerID: "p"), .init(id: "f", providerID: "p")], query: "  ")
  #expect(rows.map(\.group) == ["Favoritos", "Recentes", "Provider P", "Provider Z"])
  #expect(rows.map(\.model.id) == ["f", "r", "a", "z"])
}

@Test func paletteEffortsAreSupportedAndDefaultIsNotNone() throws {
  let model = try paletteModel("m", "Model", variants: ["max", "none", "high", "low", "xhigh", "high"])
  #expect(ModelPalette.efforts(model) == ["default", "none", "low", "high", "xhigh", "max"])
  #expect(ModelPalette.efforts(try paletteModel("simple", "Simple")) == ["default"])
  #expect(ModelPalette.effort(model, current: .init(id: "m", providerID: "p", variant: "none"), saved: "high") == "none")
  #expect(ModelPalette.effort(model, current: .init(id: "m", providerID: "other", variant: "none"), saved: "high") == "high")
  #expect(ModelPalette.effort(model, current: nil, saved: "unsupported") == "default")
  #expect(ModelPalette.label("xhigh") == "XH")
}

@Test @MainActor func paletteRecentPersistsPerServerDeduplicatesAndCaps() throws {
  let domain = "ModelPaletteTests." + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: domain))
  defer { defaults.removePersistentDomain(forName: domain) }
  let memory = ModelPaletteMemory(server: "one", defaults: defaults)
  for index in 0..<12 { memory.used(.init(id: "m\(index)", providerID: "p", variant: "high")) }
  memory.used(.init(id: "m5", providerID: "p", variant: "low"))
  #expect(memory.recent.count == 10)
  #expect(memory.recent.first == .init(id: "m5", providerID: "p"))
  #expect(memory.recent.filter { $0.id == "m5" }.count == 1)
  memory.used(.init(id: "m5", providerID: "other"))
  #expect(memory.recent.filter { $0.id == "m5" }.count == 2)
  #expect(ModelPaletteMemory(server: "one", defaults: defaults).recent == memory.recent)
  #expect(ModelPaletteMemory(server: "two", defaults: defaults).recent.isEmpty)
}
