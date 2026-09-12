export * as MCP from "./mcp.js"

import { Schema } from "effect"

export interface CallToolInput {
  readonly server: string
  readonly name: string
  readonly args?: Readonly<Record<string, unknown>>
}

export const ToolResultContent = Schema.Union([
  Schema.Struct({ type: Schema.Literal("text"), text: Schema.String }),
  Schema.Struct({ type: Schema.Literal("media"), data: Schema.String, mimeType: Schema.String }),
]).pipe(Schema.toTaggedUnion("type"))
export type ToolResultContent = typeof ToolResultContent.Type

export class ToolResult extends Schema.Class<ToolResult>("Plugin.MCP.ToolResult")({
  server: Schema.String,
  tool: Schema.String,
  isError: Schema.Boolean,
  structured: Schema.Unknown.pipe(Schema.optional),
  content: Schema.Array(ToolResultContent),
}) {}

export class CallToolError extends Schema.TaggedError<CallToolError>()("Plugin.MCP.CallToolError", {
  server: Schema.String,
  tool: Schema.String,
  message: Schema.String,
}) {}
