import { describe, expect } from "bun:test"
import type { Plugin } from "@opencode/plugin/effect"
import { Event } from "@opencode/schema/event"
import { Form } from "@opencode/schema/form"
import { Permission } from "@opencode/schema/permission"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Effect, PubSub, Stream } from "effect"
import { TestClock } from "effect/testing"
import { it } from "../../core/test/lib/effect"
import type { timed, trackRequestTimes } from "../src/request-times"

type ServerEvent = Plugin.Context["event"]["subscribe"] extends () => Stream.Stream<infer A, infer _E, infer _R>
  ? A
  : never

// The plugin loader evaluates the plugin module again for every Location; two query strings give two evaluations.
const evaluate = (
  instance: string,
): Promise<{ readonly timed: typeof timed; readonly trackRequestTimes: typeof trackRequestTimes }> =>
  import(`../src/request-times.ts?${instance}`)

const sessionID = Session.ID.make("ses_request_times")
const announced = Permission.ID.make("per_request_times_announced")
const unannounced = Permission.ID.make("per_request_times_unannounced")
const question = Form.ID.make("frm_request_times")
const permission = (id: Permission.ID): Permission.Request => ({
  id,
  sessionID,
  action: "edit",
  resources: ["/repo/a"],
})
const form: Form.Info = { id: question, sessionID, title: "Question", fields: [{ key: "answer", type: "string" }] }

describe("request times", () => {
  it.effect("shares announcement times across plugin instances, keeps first reads and forgets replies", () =>
    Effect.gen(function* () {
      const bus = yield* PubSub.unbounded<ServerEvent>()
      const event = {
        subscribe: ((input?: { readonly types?: ReadonlyArray<string> }) =>
          Stream.fromPubSub(bus).pipe(
            Stream.filter((item) => !input?.types?.length || input.types.includes(item.type)),
          )) as Plugin.Context["event"]["subscribe"],
      }
      const pending = [permission(announced), permission(unannounced)]
      const request = {
        pending: () =>
          Effect.succeed([
            { location: { directory: AbsolutePath.make("/repo") }, permissions: pending, forms: [form] },
          ]),
      }
      const [first, second] = yield* Effect.promise(() => Promise.all([evaluate("first"), evaluate("second")]))
      yield* first.trackRequestTimes(event)
      yield* PubSub.publish(bus, {
        id: Event.ID.make("evt_request_times_asked"),
        created: 100,
        type: "permission.asked",
        data: permission(announced),
      })
      yield* PubSub.publish(bus, {
        id: Event.ID.make("evt_request_times_form"),
        created: 200,
        type: "form.created",
        data: { form },
      })
      yield* Effect.yieldNow
      yield* TestClock.setTime(500)

      const read = (yield* second.timed(request).pending())[0]
      expect(read.permissions.map((item) => item.created)).toEqual([100, 500])
      expect(read.forms.map((item) => item.created)).toEqual([200])

      yield* TestClock.setTime(900)
      // A late announcement does not replace the first read; a reply forgets the request.
      yield* PubSub.publish(bus, {
        id: Event.ID.make("evt_request_times_late"),
        created: 800,
        type: "permission.asked",
        data: permission(unannounced),
      })
      yield* PubSub.publish(bus, {
        id: Event.ID.make("evt_request_times_replied"),
        created: 850,
        type: "permission.replied",
        data: { sessionID, requestID: announced, reply: "once" },
      })
      yield* Effect.yieldNow
      const again = (yield* first.timed(request).pending())[0]
      expect(again.permissions.map((item) => item.created)).toEqual([900, 500])
      expect(again.forms.map((item) => item.created)).toEqual([200])
    }),
  )
})
