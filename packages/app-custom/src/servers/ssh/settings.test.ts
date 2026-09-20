import { describe, expect, test } from "bun:test"
import { filterSshServers } from "./settings"

describe("filterSshServers", () => {
  const servers = [
    { saved: true, config: { id: "production", name: "Production", target: "dev@example.com" } },
    { saved: true, config: { id: "staging", name: "Staging", target: "dev@example.com" } },
  ]

  test("keeps text matching for the unscoped list", () => {
    expect(filterSshServers(servers, "dev@example.com")).toEqual(servers)
  })

  test("uses exact identity for scoped settings", () => {
    expect(filterSshServers(servers, "", "production")).toEqual([servers[0]])
    expect(filterSshServers(servers, "", "missing")).toEqual([])
  })
})
