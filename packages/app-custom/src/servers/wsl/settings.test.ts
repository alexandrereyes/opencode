import { describe, expect, test } from "bun:test"
import { filterWslServers } from "./settings"

describe("filterWslServers", () => {
  const servers = [
    { config: { id: "wsl:Ubuntu", distro: "Ubuntu" } },
    { config: { id: "wsl:Ubuntu-Dev", distro: "Ubuntu-Dev" } },
  ]

  test("keeps fuzzy matching for the unscoped list", () => {
    expect(filterWslServers(servers, "Ubuntu")).toEqual(servers)
  })

  test("uses exact identity for scoped settings", () => {
    expect(filterWslServers(servers, "", "wsl:Ubuntu")).toEqual([servers[0]])
    expect(filterWslServers(servers, "", "wsl:missing")).toEqual([])
  })
})
