#if DEBUG
import Foundation
import OpenCodeKit

/// Extra catalog choices for approved-screen captures. All mutations live only inside this actor.
actor MacChoicesFixture {
  static let enabled = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacChoicesFixture")
  static let shared = MacChoicesFixture()
  private var preferences: JSONValue?
  private(set) var catalogReads = 0

  func respond(_ request: URLRequest, fallback: String?) -> String? {
    guard Self.enabled else { return nil }
    let path = request.url?.path ?? ""
    if path == "/api/model" {
      catalogReads += 1
      return #"""
      {"data":[
        {"id":"opus-5.5","providerID":"llm-proxy","name":"Opus 5.5","variants":[{"id":"none"},{"id":"low"},{"id":"medium"},{"id":"high"},{"id":"xhigh"},{"id":"max"}],"limit":{"context":1000000}},
        {"id":"opus-fast","providerID":"llm-proxy","name":"Opus 5.5 (Fast)","variants":[{"id":"low"},{"id":"medium"},{"id":"high"},{"id":"xhigh"}],"limit":{"context":1000000}},
        {"id":"gpt-6-luna","providerID":"llm-proxy","name":"Luna 6","variants":[{"id":"low"},{"id":"medium"}],"limit":{"context":400000}},
        {"id":"sol-6.1","providerID":"llm-proxy","name":"Sol 6.1","limit":{"context":400000}}
      ]}
      """#
    }
    if path == "/api/rpc/custom.preferences/get" {
      if preferences == nil, let fallback, var envelope = try? JSONDecoder().decode(JSONValue.self, from: Data(fallback.utf8)).object,
        var output = envelope["output"]?.object, var data = output["data"]?.object {
        data["models"] = .object([
          "user": .array(["opus-5.5", "opus-fast", "gpt-6-luna", "sol-6.1"].map {
            .object(["providerID": .string("llm-proxy"), "modelID": .string($0), "visibility": .string("show")])
          }), "variant": .object(["llm-proxy/opus-fast": .string("medium")]),
          "favorites": .array([.object(["providerID": .string("llm-proxy"), "modelID": .string("opus-fast")])]),
          "default": .object(["providerID": .string("llm-proxy"), "modelID": .string("opus-5.5"), "variant": .string("xhigh")]),
        ])
        output["data"] = .object(data)
        envelope["output"] = .object(output)
        preferences = .object(envelope)
      }
      return preferences.flatMap(encode)
    }
    if path == "/api/rpc/custom.preferences/mutate", let body = request.httpBody,
      let input = try? JSONDecoder().decode(JSONValue.self, from: body).object?["input"]?.object,
      var envelope = preferences?.object, var output = envelope["output"]?.object, var data = output["data"]?.object,
      var models = data["models"]?.object {
      let intent = input["intent"]?.object ?? input
      if intent["type"]?.string == "model.favorite", let id = intent["modelID"]?.string,
        let provider = intent["providerID"]?.string {
        var favorites = models["favorites"]?.array ?? []
        favorites.removeAll { $0.object?["modelID"]?.string == id && $0.object?["providerID"]?.string == provider }
        if intent["favorite"]?.bool == true { favorites.append(.object(["modelID": .string(id), "providerID": .string(provider)])) }
        models["favorites"] = .array(favorites)
      }
      if intent["type"]?.string == "model.default" { models["default"] = intent["model"] }
      data["models"] = .object(models)
      output["data"] = .object(data)
      output["revision"] = .number((output["revision"]?.number ?? 1) + 1)
      envelope["output"] = .object(output)
      preferences = .object(envelope)
      return preferences.flatMap(encode)
    }
    return nil
  }

  private func encode(_ value: JSONValue) -> String? {
    (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
  }
}
#endif
