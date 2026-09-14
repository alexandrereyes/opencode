import { expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { loadTuiUpdater } from "../src/services/tui-updater"

test("loads a trusted TUI updater with the resolved endpoint and rejects malformed adapters", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "opencode-tui-updater-"))
  await using cleanup = {
    async [Symbol.asyncDispose]() {
      await rm(directory, { recursive: true, force: true })
    },
  }
  const file = path.join(directory, "updater.mjs")
  const invalid = path.join(directory, "invalid.mjs")
  await Bun.write(invalid, "export const createUpdater = () => ({})")
  await Bun.write(
    file,
    `export function createUpdater({endpoint}) { return {
    remote: true, subscribe: async () => {}, apply: async () => {},
    check: async () => ({type: "unavailable", message: endpoint.url})
  } }`,
  )
  const updater = await loadTuiUpdater(file, { url: "http://127.0.0.1:1111" })
  expect(await updater.check(new AbortController().signal)).toEqual({
    type: "unavailable",
    message: "http://127.0.0.1:1111",
  })
  await expect(loadTuiUpdater(invalid, { url: "http://unused" })).rejects.toThrow("Invalid TUI updater adapter")
})
