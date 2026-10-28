#!/usr/bin/env bun
/**
 * Local cleartext HTTP/2 stand-in for APNs, for a sandbox started with `OPENCODE_APNS_ORIGIN=http://127.0.0.1:<port>`.
 * Answers 200 to everything and appends each request (path, APNs headers and body; never the provider token) to a
 * JSONL file, so tests can read what the server would have sent without reaching Apple or any device.
 *
 *   bun packages/ios-custom/script/fake-apns.ts --port 4190 --log /path/to/apns.jsonl
 */
import { appendFile } from "node:fs/promises"
import http2 from "node:http2"
import { parseArgs } from "node:util"

const args = parseArgs({ args: Bun.argv.slice(2), options: { port: { type: "string" }, log: { type: "string" } } })
if (!args.values.port || !args.values.log) throw new Error("Usage: fake-apns.ts --port N --log FILE")
const log = args.values.log
const server = http2.createServer()
server.on("stream", (stream, headers) => {
  const chunks: Buffer[] = []
  stream.on("data", (chunk: Buffer) => chunks.push(chunk))
  stream.on("end", () => {
    const entry = {
      at: Date.now(),
      path: headers[":path"],
      type: headers["apns-push-type"],
      topic: headers["apns-topic"],
      priority: headers["apns-priority"],
      expiration: headers["apns-expiration"],
      body: JSON.parse(Buffer.concat(chunks).toString("utf8") || "null"),
    }
    void appendFile(log, JSON.stringify(entry) + "\n", { mode: 0o600 })
    stream.respond({ ":status": 200, "apns-id": crypto.randomUUID() })
    stream.end()
  })
})
server.listen(Number(args.values.port), "127.0.0.1", () => console.log(`fake APNs on http://127.0.0.1:${args.values.port}`))
