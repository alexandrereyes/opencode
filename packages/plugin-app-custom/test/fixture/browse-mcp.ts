/**
 * A stand-in for browse 0.1.0's MCP server (`browse mcp`, the plain tools OpenCode gets) for
 * `script/e2e-browser-handoff.ts`: no relay, no browser. `navigate` answers at once with tab 1; `handoff` blocks like a
 * real one until the file `$BROWSE_FAKE_RELEASE_DIR/tab-<tab>` exists (`{"outcome":"continued"}`) or
 * `BROWSE_FAKE_TIMEOUT_MS` passes (browse's timeout answer). With `BROWSE_FAKE_CALLS_LOG`, every call that reaches the
 * server is appended there as one JSON line.
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js"
import { appendFileSync, existsSync } from "node:fs"
import path from "node:path"

const releases = process.env.BROWSE_FAKE_RELEASE_DIR ?? ""
const timeout = Number(process.env.BROWSE_FAKE_TIMEOUT_MS ?? 120_000)
const calls = process.env.BROWSE_FAKE_CALLS_LOG ?? ""
const server = new Server(
  { name: "browse", version: "0.0.0-fake" },
  { capabilities: { tools: {} }, instructions: "Fake browse for tests: no browser." },
)

const tab = { type: "integer", description: "The tab to act on." }
server.setRequestHandler(ListToolsRequestSchema, () =>
  Promise.resolve({
    tools: [
      {
        name: "navigate",
        description: "Open a page (fake: no browser). Without `tab` it opens a new tab and returns its id as `tab`.",
        inputSchema: { type: "object", properties: { url: { type: "string" }, tab }, required: [] },
      },
      {
        name: "handoff",
        description: "Ask the user to do something in a tab and wait until they click Continue (fake: a release file).",
        inputSchema: {
          type: "object",
          properties: { message: { type: "string" }, tab, timeoutSeconds: { type: "integer" } },
          required: ["message", "tab"],
        },
      },
    ],
  }),
)

const text = (value: unknown, isError = false) => ({
  content: [{ type: "text" as const, text: JSON.stringify(value) }],
  ...(isError ? { isError } : {}),
})

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const args = (request.params.arguments ?? {}) as { url?: unknown; tab?: unknown }
  if (calls) appendFileSync(calls, JSON.stringify({ name: request.params.name, arguments: args }) + "\n")
  if (request.params.name === "navigate") return text({ url: args.url, navigated: true, tab: args.tab ?? 1 })
  const deadline = Date.now() + timeout
  const release = path.join(releases, `tab-${String(args.tab)}`)
  while (Date.now() < deadline && !(releases && existsSync(release))) await Bun.sleep(200)
  if (Date.now() >= deadline) return text({ outcome: "timeout", tab: args.tab }, true)
  return text({ outcome: "continued", tab: args.tab })
})

await server.connect(new StdioServerTransport())
