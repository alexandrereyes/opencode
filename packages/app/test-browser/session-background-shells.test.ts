import { expect, test } from "bun:test"
import { OpenCode } from "@opencode/client/promise"
import { syncSessionBackgroundShells } from "@/session/requests/background-shells"

test("discovers every prior session location through filtered pagination", async () => {
  const requests: URL[] = []
  const api = OpenCode.make({
    baseUrl: "http://opencode.local",
    fetch: (input, init) => {
      const url = new URL((input instanceof Request ? input : new Request(input, init)).url)
      requests.push(url)
      const cursor = url.searchParams.get("cursor")
      if (!cursor)
        return Promise.resolve(
          Response.json({
            data: [
              {
                id: "msg_second_move",
                type: "location-switched",
                location: { directory: "/current" },
                previous: { location: { directory: "/middle", workspaceID: "ws_middle" } },
                time: { created: 2 },
              },
            ],
            cursor: { next: "older" },
          }),
        )
      return Promise.resolve(
        Response.json({
          data: [
            {
              id: "msg_first_move",
              type: "location-switched",
              location: { directory: "/middle", workspaceID: "ws_middle" },
              previous: { location: { directory: "/origin" } },
              time: { created: 1 },
            },
          ],
          cursor: {},
        }),
      )
    },
  })
  const synced: string[] = []

  await syncSessionBackgroundShells({
    sessionID: "ses_moved",
    current: { directory: "/current" },
    known: [{ directory: "/origin" }],
    message: api.message,
    sync: async (location) => {
      synced.push(JSON.stringify([location.directory, location.workspaceID]))
    },
  })

  expect(
    requests.map((url) => [
      url.pathname,
      url.searchParams.get("type"),
      url.searchParams.get("limit"),
      url.searchParams.get("order"),
      url.searchParams.get("cursor"),
    ]),
  ).toEqual([
    ["/api/session/ses_moved/message", "location-switched", "200", "desc", null],
    ["/api/session/ses_moved/message", "location-switched", "200", null, "older"],
  ])
  expect(synced).toEqual([
    '["/current",null]',
    '["/origin",null]',
    '["/middle","ws_middle"]',
  ])
})

test("still refreshes current and known runtime locations when move history fails", async () => {
  const api = OpenCode.make({
    baseUrl: "http://opencode.local",
    fetch: () => Promise.resolve(new Response("unavailable", { status: 503 })),
  })
  const synced: string[] = []

  await syncSessionBackgroundShells({
    sessionID: "ses_moved",
    current: { directory: "/current" },
    known: [{ directory: "/origin" }],
    message: api.message,
    sync: async (location) => {
      synced.push(location.directory)
    },
  })

  expect(synced).toEqual(["/current", "/origin"])
})
