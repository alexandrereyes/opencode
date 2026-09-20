import { describe, expect, test } from "bun:test"
import { ServerConnection } from "@/runtime/server/registry"
import { sortServerConnections } from "./controller"

const server = (url: string): ServerConnection.Http => ({ type: "http", http: { url } })

describe("sortServerConnections", () => {
  test("places the default first before ordering by health", () => {
    const healthy = server("http://healthy")
    const offline = server("http://offline")
    const unknown = server("http://unknown")
    const result = sortServerConnections({
      servers: [unknown, healthy, offline],
      health: {
        [ServerConnection.key(healthy)]: { healthy: true },
        [ServerConnection.key(offline)]: { healthy: false },
      },
      defaultKey: ServerConnection.key(offline),
    })

    expect(result).toEqual([offline, healthy, unknown])
  })

  test("preserves insertion order within each health group", () => {
    const healthyFirst = server("http://healthy-first")
    const unknownFirst = server("http://unknown-first")
    const offlineFirst = server("http://offline-first")
    const healthySecond = server("http://healthy-second")
    const unknownSecond = server("http://unknown-second")
    const offlineSecond = server("http://offline-second")
    const servers = [unknownFirst, offlineFirst, healthyFirst, unknownSecond, healthySecond, offlineSecond]
    const result = sortServerConnections({
      servers,
      health: {
        [ServerConnection.key(healthyFirst)]: { healthy: true },
        [ServerConnection.key(healthySecond)]: { healthy: true },
        [ServerConnection.key(offlineFirst)]: { healthy: false },
        [ServerConnection.key(offlineSecond)]: { healthy: false },
      },
      defaultKey: null,
    })

    expect(result).toEqual([healthyFirst, healthySecond, unknownFirst, unknownSecond, offlineFirst, offlineSecond])
    expect(servers).toEqual([unknownFirst, offlineFirst, healthyFirst, unknownSecond, healthySecond, offlineSecond])
  })
})
