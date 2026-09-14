import plugin from "../../plugin-app-custom/src/index"
import { Plugin } from "@opencode/plugin/effect"
import type { Rpc } from "@opencode/schema/rpc"
import type { Tool } from "@opencode/schema/tool"
import { Schema } from "effect"

// Bundled codecs must execute in their defining runtime. Standard Schema is
// the public host boundary; do not pass bundled Effect Schema ASTs to the host.
export default Plugin.define({
  id: plugin.id,
  effect: (ctx) => {
    const register: Plugin.Context["rpc"]["register"] = (definition, handlers) =>
      ctx.rpc.register(transport(definition), handlers)
    const rpc = Object.assign(<D extends Rpc.Definition>(definition: D) => ctx.rpc(definition), { register })
    return plugin.effect({ ...ctx, rpc })
  },
})

function transport<D extends Rpc.Definition>(definition: D): D {
  return {
    ...definition,
    methods: Object.fromEntries(
      Object.entries(definition.methods).map(([name, method]) => [
        name,
        {
          ...method,
          input: portable(method.input, false),
          output: portable(method.output, true),
          ...(method.errors
            ? {
                errors: Object.fromEntries(
                  Object.entries(method.errors).flatMap(([key, schema]) =>
                    schema === undefined ? [] : [[key, portable(schema, true)]],
                  ),
                ),
              }
            : {}),
        },
      ]),
    ),
    events: Object.fromEntries(
      Object.entries(definition.events).map(([name, event]) => [
        name,
        { ...event, schema: portable(event.schema, true) },
      ]),
    ),
  } as D
}

function portable(schema: Tool.ValueSchema, encode: boolean) {
  if (!Schema.isSchema(schema)) return schema
  return { "~standard": Schema.toStandardSchemaV1(encode ? Schema.flip(schema) : schema)["~standard"] }
}
