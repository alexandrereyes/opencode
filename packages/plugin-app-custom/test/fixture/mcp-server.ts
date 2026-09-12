import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js"

const server = new Server({ name: "app-mentions", version: "1.0.0" }, { capabilities: { tools: {} } })

server.setRequestHandler(ListToolsRequestSchema, () =>
  Promise.resolve({ tools: [{ name: "list_apps", inputSchema: { type: "object" } }] }),
)
server.setRequestHandler(CallToolRequestSchema, () =>
  Promise.resolve({
    content: [
      {
        type: "text",
        text: `${process.env.APP_MENTION_FIXTURE_NAME ?? "Safari"} — ${process.env.APP_MENTION_FIXTURE_BUNDLE ?? "com.apple.Safari"} [running]`,
      },
    ],
  }),
)

await server.connect(new StdioServerTransport())
