import type { Rpc } from "@opencode/schema/rpc"
import type { Tool } from "@opencode/schema/tool"
import { Schema } from "effect"

/** Keep a bundled sidecar's codecs in its own runtime, preserving the host's
 * input-decode and result/error/event-encode directions at registration.
 */
export function transportDefinition<D extends Rpc.Definition>(definition: D): D {
  // The method/event names and logical handler types are unchanged. Only the
  // schema execution boundary is adapted; no caller-facing contract is edited.
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
                  Object.entries(method.errors).flatMap(([name, schema]) =>
                    schema === undefined ? [] : [[name, portable(schema, true)] as const],
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
        {
          ...event,
          schema: Schema.isSchema(event.schema)
            ? { "~standard": Schema.toStandardSchemaV1(Schema.flip(event.schema))["~standard"] }
            : event.schema,
        },
      ]),
    ),
  } as D
}

function portable(schema: Tool.ValueSchema, encode: boolean) {
  if (!Schema.isSchema(schema)) return schema
  return { "~standard": Schema.toStandardSchemaV1(encode ? Schema.flip(schema) : schema)["~standard"] }
}
