import { expect } from "bun:test"
import { Effect } from "effect"
import { Location } from "@opencode/core/location"
import { Model } from "@opencode/core/model"
import { Plugin } from "@opencode/core/plugin"
import { PluginHost } from "@opencode/core/plugin/host"
import { Provider } from "@opencode/core/provider"
import { Rpc } from "@opencode/core/rpc"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { testEffect } from "./lib/effect"
import { PluginTestLayer } from "./plugin/fixture"
import { Chats } from "../../plugin-app-custom/src/chats/rpc"
import { agentID, registerMaster } from "../../plugin-app-custom/src/master"
import { Master } from "../../plugin-app-custom/src/master/rpc"
import { registerPreferences } from "../../plugin-app-custom/src/preferences"
import { atomic } from "../../plugin-app-custom/src/storage"

const providerID = Provider.ID.make("llm-proxy")
const luna = Model.Ref.make({ providerID, id: Model.ID.make("gpt-6-luna"), variant: Model.VariantID.make("low") })

testEffect(PluginTestLayer).live(
  "Mestra ensure creates one session for concurrent callers and recreates a deleted or archived one",
  () =>
    Effect.gen(function* () {
      const plugins = yield* Plugin.Service
      const rpc = yield* Rpc.Service
      const location = yield* Location.Service
      const ctx = yield* PluginHost.make(plugins)
      const claims: string[] = []
      // Managed chats allocate under the user's data directory; this Location stands in for each allocation.
      yield* ctx.rpc
        .register(Chats.Definition, {
          info: () => Effect.succeed({ root: AbsolutePath.make(location.directory) }),
          allocate: () =>
            Effect.succeed({ id: `chat-${claims.length}`, directory: AbsolutePath.make(location.directory) }),
          claim: (input) => Effect.sync(() => void claims.push(`claim:${input.sessionID}`)).pipe(Effect.as({})),
          confirm: (input) => Effect.sync(() => void claims.push(`confirm:${input.sessionID}`)).pipe(Effect.as({})),
        })
        .pipe(Effect.orDie)
      yield* registerPreferences({ ...ctx, storage: atomic(ctx.storage) })
      yield* registerMaster(ctx)
      yield* ctx.provider.transform((editor) =>
        editor.add({
          info: { ...Provider.Info.empty(providerID), activation: "enabled" },
          models: [
            {
              ...Model.Info.default(providerID, Model.ID.make("gpt-6-luna")),
              variants: [{ id: Model.VariantID.make("low") }],
            },
          ],
        }),
      )
      const master = ctx.rpc(Master.Definition)

      const [first, second] = yield* Effect.all([master.ensure({ model: luna }), master.ensure({})], {
        concurrency: "unbounded",
      })
      expect(first.sessionID).toBe(second.sessionID)
      expect([first.created, second.created].filter(Boolean)).toHaveLength(1)
      expect(claims).toEqual([`claim:${first.sessionID}`, `confirm:${first.sessionID}`])
      expect(first.preferences.data.masterSessions).toEqual({ local: first.sessionID })
      const created = yield* ctx.session.get({ sessionID: first.sessionID })
      expect(created).toMatchObject({
        agent: agentID,
        model: luna,
        title: "Sessão mestra",
        location: { directory: location.directory },
      })
      expect(yield* master.ensure({})).toMatchObject({ sessionID: first.sessionID, created: false })

      // The model chosen for the first Mestra is remembered and carried into its replacement.
      yield* ctx.session.remove({ sessionID: first.sessionID })
      const replaced = yield* master.ensure({})
      expect(replaced).toMatchObject({ created: true, preferences: { data: { masterSessions: { local: replaced.sessionID } } } })
      expect(replaced.sessionID).not.toBe(first.sessionID)
      expect(yield* ctx.session.get({ sessionID: replaced.sessionID })).toMatchObject({ agent: agentID, model: luna })
      const profile = yield* rpc.call("custom.preferences", "get", {})
      expect(profile).toMatchObject({ data: { masterSessions: { local: replaced.sessionID } } })

      yield* ctx.session.update({ sessionID: replaced.sessionID, archived: true })
      const unarchived = yield* master.ensure({})
      expect(unarchived.created).toBe(true)
      expect([first.sessionID, replaced.sessionID]).not.toContain(Session.ID.make(unarchived.sessionID))
    }),
)
