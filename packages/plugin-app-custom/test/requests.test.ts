import { expect, test } from "bun:test"
import { Effect, Schema } from "effect"
import { Permission } from "@opencode/schema/permission"
import { Session } from "@opencode/schema/session"
import { AbsolutePath } from "@opencode/schema/schema"
import { permissions } from "../src/requests"
import { Requests } from "../src/requests/rpc"

test("returns permissions from every live location, including unknown idle sessions", async () => {
  const requests = ["first", "second"].map((id) =>
    Schema.decodeUnknownSync(Permission.Request)({
      id: Permission.ID.create(),
      sessionID: Session.ID.create(),
      action: id,
      resources: [],
      created: 123,
    }),
  )
  const result = await Effect.runPromise(
    permissions({
      pending: () =>
        Effect.succeed(
          requests.map((request, index) => ({
            location: { directory: AbsolutePath.make(`/location-${index}`) },
            permissions: [request],
            forms: [],
          })),
        ),
    }),
  )
  expect(Requests.Definition.id).toBe("custom.requests")
  expect(result).toEqual(requests.map((request) => Schema.encodeSync(Permission.Request)(request)))
  expect(await Requests.Definition.methods.permissions.output["~standard"].validate(result)).toEqual({ value: result })
  expect(await Effect.runPromise(permissions({ pending: () => Effect.succeed([]) }))).toEqual([])
})
