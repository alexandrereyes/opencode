import assert from "node:assert/strict"
import { it } from "node:test"
import { Effect } from "effect"
import { Form } from "@opencode/schema/form"
import { Session } from "@opencode/schema/session"
import { Plugin } from "../src/effect/index.js"
import { fromPromise } from "../src/promise/adapter.js"
import { host } from "../../core/test/plugin/host"

it("Promise session active and form reply reuse the client contracts and native Effect inputs", async () => {
  const sessionID = Session.ID.make("ses_adapter")
  const formID = Form.ID.make("frm_adapter")
  const replies: Array<Parameters<Plugin.Context["session"]["form"]["reply"]>[0]> = []
  await Effect.runPromise(
    Effect.scoped(
      fromPromise({
        id: "test.session-controls",
        async setup(ctx) {
          assert.deepEqual(await ctx.session.active(), { [sessionID]: { type: "running" } })
          assert.equal(
            await ctx.session.form.reply({ sessionID, formID, answer: { choice: ["a", "b"], confirmed: true } }),
            undefined,
          )
        },
      }).effect(
        host({
          session: {
            active: () => Effect.succeed({ [sessionID]: { type: "running" } }),
            form: {
              reply: (input) =>
                Effect.sync(() => {
                  replies.push(input)
                }),
            },
          },
        }),
      ),
    ),
  )
  assert.deepEqual(replies, [{ sessionID, formID, answer: { choice: ["a", "b"], confirmed: true } }])
})

it("Promise form reply validates the native form ID before delegation and preserves failures", async () => {
  const calls: string[] = []
  await Effect.runPromise(
    Effect.scoped(
      fromPromise({
        id: "test.session-control-errors",
        async setup(ctx) {
          await assert.rejects(ctx.session.form.reply({ sessionID: "ses_owner", formID: "invalid", answer: {} }))
          await assert.rejects(
            ctx.session.form.reply({ sessionID: "ses_owner", formID: "frm_valid", answer: {} }),
            /native refusal/,
          )
        },
      }).effect(
        host({
          session: {
            form: {
              reply: (input) => {
                calls.push(input.formID)
                return Effect.fail(new Error("native refusal"))
              },
            },
          },
        }),
      ),
    ),
  )
  assert.deepEqual(calls, ["frm_valid"])
})
