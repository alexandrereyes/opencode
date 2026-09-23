import { expect, test } from "bun:test"
import type { IntegrationInfo } from "@opencode/client/promise"
import { popularConnections } from "./popular"

const providers = [{ id: "anthropic" }, { id: "opencode" }, { id: "opencode-go" }]
const integration = (method?: "key" | "oauth"): IntegrationInfo => ({
  id: "opencode",
  name: "OpenCode Console",
  methods: [],
  connections: method ? [{ type: "credential", id: "cred_fixture", label: "Fixture", method }] : [],
})

test("fresh installs offer Console and Go", () => {
  expect(popularConnections(providers, new Set(), integration()).map((item) => item.id)).toEqual([
    "opencode-go",
    "opencode",
    "anthropic",
  ])
})

test("a Zen API key keeps Console sign-in available while connected providers stay deduplicated", () => {
  expect(popularConnections(providers, new Set(["opencode", "anthropic"]), integration("key"))).toEqual([
    { id: "opencode-go" },
    { id: "opencode" },
  ])
})

test("an OAuth account hides Console sign-in even with only free models", () => {
  expect(popularConnections(providers, new Set(), integration("oauth")).map((item) => item.id)).toEqual([
    "opencode-go",
    "anthropic",
  ])
})

test("deduplicates the legacy catalog until integrations load", () => {
  expect(popularConnections(providers, new Set(["opencode"]), undefined).map((item) => item.id)).toEqual([
    "opencode-go",
    "anthropic",
  ])
})
