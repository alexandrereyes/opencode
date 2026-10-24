import { expect } from "bun:test"
import { Effect } from "effect"
import { Agent } from "@opencode/core/agent"
import { Model } from "@opencode/core/model"
import { Plugin } from "@opencode/core/plugin"
import { PluginHooks } from "@opencode/core/plugin/hooks"
import { PluginHost } from "@opencode/core/plugin/host"
import { Provider } from "@opencode/core/provider"
import { Rpc } from "@opencode/core/rpc"
import { testEffect } from "./lib/effect"
import { OfflinePluginTestLayer } from "./plugin/fixture"
import { agentID, preferredModel, registerMaster } from "../../plugin-app-custom/src/master"

const providerID = Provider.ID.make("llm-proxy")
const catalog = (id: string, variants: string[]) => ({
  ...Model.Info.default(providerID, Model.ID.make(id)),
  variants: variants.map((variant) => ({ id: Model.VariantID.make(variant) })),
})
const luna = Model.Ref.make({ providerID, id: Model.ID.make("gpt-6-luna"), variant: Model.VariantID.make("low") })

testEffect(OfflinePluginTestLayer).live(
  "Mestra info resolves providers registered after the plugin and follows real Mestra model selections",
  () =>
    Effect.gen(function* () {
      const plugins = yield* Plugin.Service
      const rpc = yield* Rpc.Service
      const hooks = yield* PluginHooks.Service
      const ctx = yield* PluginHost.make(plugins)
      const info = rpc.call("custom.master", "info", {})
      yield* registerMaster(ctx)
      expect(yield* info).toEqual({ version: 1, agent: agentID })

      // Configured providers are contributed by plugins that run after the custom package.
      yield* ctx.provider.transform((editor) =>
        editor.add({
          info: { ...Provider.Info.empty(providerID), activation: "enabled" },
          models: [catalog("gpt-6.1-sol-ultrafast", ["low", "medium"]), catalog("gpt-6-luna", ["low", "high"])],
        }),
      )
      expect(yield* info).toEqual({ version: 1, agent: agentID, model: preferredModel })

      const master = yield* ctx.session.create({ agent: agentID, model: preferredModel })
      yield* ctx.session.switchModel({ sessionID: master.id, model: luna })
      expect(yield* until(info, { version: 1, agent: agentID, model: luna })).toEqual({
        version: 1,
        agent: agentID,
        model: luna,
      })

      const high = { ...luna, variant: Model.VariantID.make("high") }
      yield* ctx.session.create({ agent: agentID, model: high })
      expect(yield* until(info, { version: 1, agent: agentID, model: high })).toEqual({
        version: 1,
        agent: agentID,
        model: high,
      })

      // Every Mestra step records its model in the session's own Location, even if no selection event was seen.
      const step = (agent: Agent.ID, model: Model.Ref) => {
        const event = {
          sessionID: master.id,
          agent,
          model,
          system: [],
          messages: [],
          tools: { subagent: { description: "", input: {} } },
          options: {},
        }
        return hooks.trigger("session", "context", event).pipe(Effect.as(event))
      }
      expect((yield* step(Agent.ID.make("build"), luna)).tools).toHaveProperty("subagent")
      expect(yield* info).toEqual({ version: 1, agent: agentID, model: high })
      expect((yield* step(agentID, preferredModel)).tools).not.toHaveProperty("subagent")
      expect(yield* info).toEqual({ version: 1, agent: agentID, model: preferredModel })
    }),
)

// The plugin observes durable session events on its own fiber.
function until<A>(effect: Effect.Effect<A, unknown>, expected: A) {
  return Effect.gen(function* () {
    const deadline = Date.now() + 10_000
    while (true) {
      const value = yield* effect
      if (Bun.deepEquals(value, expected) || Date.now() > deadline) return value
      yield* Effect.sleep("10 millis")
    }
  })
}
