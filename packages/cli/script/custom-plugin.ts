import plugin from "../../plugin-app-custom/src/index"
import { flag, main } from "../../plugin-app-custom/src/resources/hub/main"
import { Plugin } from "@opencode/plugin/effect"
import type { RpcClient } from "@opencode/plugin/effect/rpc"
import type { Rpc } from "@opencode/schema/rpc"
import type { Tool } from "@opencode/schema/tool"
import { Effect, Schema } from "effect"

// The release ships one plugin file; the resources hub runs from it as a separate process
// (`BUN_BE_BUN=1 opencode plugin/index.js --opencode-resources-hub`).
if (process.argv.includes(flag)) await main()

// Bundled codecs must execute in their defining runtime. Standard Schema is
// the public host boundary; do not pass bundled Effect Schema ASTs to the host.
export default Plugin.define({
  id: plugin.id,
  effect: (ctx) => {
    const register: Plugin.Context["rpc"]["register"] = (definition, handlers) =>
      ctx.rpc.register(transport(definition), handlers)
    const rpc = Object.assign(
      <D extends Rpc.Definition>(definition: D) => client(definition, ctx.rpc(transport(definition))),
      { register },
    )
    return plugin.effect({ ...ctx, rpc })
  },
})

// Calls cross the host as encoded values, so the bundled codecs encode inputs and decode outputs here.
function client<D extends Rpc.Definition>(definition: D, remote: RpcClient<D, Rpc.SystemError, never, unknown>) {
  // SAFETY: The host client exposes one function per definition method.
  // oxlint-disable-next-line typescript-eslint/no-unsafe-type-assertion
  const call = remote as unknown as Record<
    string,
    (input: unknown, options?: unknown) => Effect.Effect<unknown, unknown>
  >
  const methods = Object.fromEntries(
    Object.entries(definition.methods).map(([name, method]) => [
      name,
      (input: unknown, options?: unknown) =>
        codec(method.input, input, "encode").pipe(
          Effect.flatMap((encoded) => call[name](encoded, options)),
          Effect.flatMap((output) => codec(method.output, output, "decode")),
        ),
    ]),
  )
  // SAFETY: Every method keeps its definition's input and output types; only the codec runtime changes.
  // oxlint-disable-next-line typescript-eslint/no-unsafe-type-assertion
  return { ...methods, events: remote.events } as unknown as RpcClient<D, Rpc.SystemError, never, unknown>
}

function codec(schema: Tool.ValueSchema, value: unknown, direction: "encode" | "decode") {
  if (!Schema.isSchema(schema)) return Effect.succeed(value)
  return (direction === "encode" ? Schema.encodeUnknownEffect(schema) : Schema.decodeUnknownEffect(schema))(value).pipe(
    Effect.orDie,
  )
}

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
