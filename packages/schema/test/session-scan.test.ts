import { expect, test } from "bun:test"
import { Schema } from "effect"
import { SessionScan } from "../src/session-scan.js"

test("session scan encodes browser-safe timestamps and omits absent facts", () => {
  const encoded = {
    data: [
      {
        session: {
          id: "ses_scan",
          projectID: "global",
          location: { directory: "/repo" },
          time: { created: 10, updated: 20, idle: 30 },
          cost: 0,
          tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
        },
        messageAt: 25,
      },
    ],
  }
  const decoded = Schema.decodeUnknownSync(SessionScan.Page)(encoded)
  expect(Schema.encodeSync(SessionScan.Page)(decoded)).toEqual(encoded)
})
