import type { McpApi } from "@opencode/client/effect/api"
import type { Mcp } from "@opencode/schema/mcp"
import type { Effect, Types } from "effect"
import type { CallToolError, CallToolInput, ToolResult } from "../mcp.js"
import type { Transform } from "./registration.js"

export interface MCPEditor {
  list(): readonly [string, Types.DeepMutable<Mcp.ServerConfig>][]
  get(name: string): Types.DeepMutable<Mcp.ServerConfig> | undefined
  set(name: string, config: Mcp.ServerConfig): void
  update(name: string, update: (config: Types.DeepMutable<Mcp.ServerConfig>) => void): void
  remove(name: string): void
}

export interface MCPDomain extends Pick<McpApi<unknown>, "list"> {
  readonly callTool: (input: CallToolInput) => Effect.Effect<ToolResult, CallToolError>
  readonly transform: Transform<MCPEditor>
  readonly reload: () => Effect.Effect<void>
}
