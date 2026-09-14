import plugin from "../index.js"
import { Plugin } from "@opencode/plugin/effect"
import type { Rpc } from "@opencode/schema/rpc"
import { transportDefinition } from "./transport.js"

/** Deployment-only boundary. Source plugins and public RPC contracts stay native. */
export default Plugin.define({
  id: plugin.id,
  effect: (ctx) => {
    const register: Plugin.Context["rpc"]["register"] = (definition, handlers) =>
      ctx.rpc.register(transportDefinition(definition), handlers)
    const rpc = Object.assign(<D extends Rpc.Definition>(definition: D) => ctx.rpc(definition), { register })
    return plugin.effect({ ...ctx, rpc })
  },
})
