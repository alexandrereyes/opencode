/**
 * A stand-in for browse's MCP server (`browse mcp`) for tests and `script/e2e-browser-handoff.ts`: no relay, no
 * browser. `execute` blocks like a real `handoff()` while its code calls `handoff(` or `demonstrate(`, until the file
 * `$BROWSE_FAKE_RELEASE_DIR/<name>` exists (the name is the code's `release:<name>` comment, else `default`) or
 * `BROWSE_FAKE_TIMEOUT_MS` passes; any other code returns at once. `network` (`script/e2e-browse-guard.ts`) only
 * answers. With `BROWSE_FAKE_CALLS_LOG`, every call that reaches the server is appended there as one JSON line.
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
  { capabilities: { tools: {} }, instructions: "Fake browse for tests: execute runs no browser." },
)

server.setRequestHandler(ListToolsRequestSchema, () =>
  Promise.resolve({
    tools: [
      {
        name: "execute",
        description: "Execute Playwright JavaScript against the browse session (fake: no browser).",
        inputSchema: {
          type: "object",
          properties: { code: { type: "string", description: "JavaScript code to execute." } },
          required: ["code"],
        },
      },
      {
        name: "network",
        description: "Start, inspect, stop, or cancel session-scoped network capture (fake: nothing is captured).",
        inputSchema: {
          type: "object",
          properties: {
            action: { type: "string", enum: ["start", "status", "stop", "cancel"] },
            outputPath: { type: "string", description: "For stop: credential-redacted HAR path." },
            secrets: { type: "string", description: "For stop: reusable profile name for captured credentials." },
          },
          required: ["action"],
        },
      },
    ],
  }),
)

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (calls)
    appendFileSync(calls, JSON.stringify({ name: request.params.name, arguments: request.params.arguments }) + "\n")
  if (request.params.name === "network") return { content: [{ type: "text", text: JSON.stringify({ ok: true }) }] }
  const code = String((request.params.arguments as { code?: unknown } | undefined)?.code ?? "")
  if (/\b(handoff|demonstrate)\s*\(/.test(code)) {
    const name = code.match(/release:([\w-]+)/)?.[1] ?? "default"
    const deadline = Date.now() + timeout
    while (Date.now() < deadline && !(releases && existsSync(path.join(releases, name)))) await Bun.sleep(200)
    if (Date.now() >= deadline)
      return { content: [{ type: "text", text: "Handoff timed out waiting for the user" }], isError: true }
    return { content: [{ type: "text", text: JSON.stringify({ value: "continued", aftermath: { handoffs: 1 } }) }] }
  }
  return { content: [{ type: "text", text: JSON.stringify({ value: "ok", aftermath: { handoffs: 0 } }) }] }
})

await server.connect(new StdioServerTransport())
