import { afterAll, afterEach, beforeAll, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { CDP, withoutQuery } from "../src/resources/adapters/cdp"
import { handoffTab, listPages, makeChromeAdapter, relayTokenFile } from "../src/resources/adapters/chrome"
import { entryOf, fakeBrowser, token, watch } from "./fixture/fake-chrome"

/**
 * The Chrome adapter's browse mode (`docs/browse-handoff-remoto.md`) against a fake browse relay: the relay token, the
 * session's handoff tab and nothing else.
 */

const directory = await fs.mkdtemp(path.join(os.tmpdir(), "browse-relay-"))
const tokenFile = path.join(directory, "relay-token")
const inherited = process.env.OPENCODE_BROWSE_RELAY_TOKEN_FILE
beforeAll(async () => {
  await Bun.write(tokenFile, `${token}\n`)
  process.env.OPENCODE_BROWSE_RELAY_TOKEN_FILE = tokenFile
})
afterAll(async () => {
  if (inherited === undefined) delete process.env.OPENCODE_BROWSE_RELAY_TOKEN_FILE
  else process.env.OPENCODE_BROWSE_RELAY_TOKEN_FILE = inherited
  await fs.rm(directory, { recursive: true, force: true })
})
const stops: (() => unknown)[] = []
afterEach(async () => {
  await Promise.all(stops.splice(0).map((stop) => stop()))
})

test("the relay token is read where browse keeps it", () => {
  const home = os.homedir()
  expect(relayTokenFile({})).toBe(path.join(home, ".local/share/browse/relay-token"))
  expect(relayTokenFile({ XDG_DATA_HOME: "/x/data" })).toBe("/x/data/browse/relay-token")
  expect(relayTokenFile({ XDG_DATA_HOME: "relative" })).toBe(path.join(home, ".local/share/browse/relay-token"))
  expect(relayTokenFile({ OPENCODE_BROWSER_HOME: "/x/browse", XDG_DATA_HOME: "/x/data" })).toBe("/x/browse/relay-token")
  expect(relayTokenFile({ OPENCODE_BROWSE_RELAY_TOKEN_FILE: "/x/token" })).toBe("/x/token")
})

test("the handoff's tab is the session's own page; other sessions' tabs and the token never come out", async () => {
  const relay = fakeBrowser({ token })
  stops.push(() => relay.server.stop(true))
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  // The relay lists every session's tabs; only this session's survive.
  expect((await listPages(relay.server.port!, "login")).map((page) => page.targetId)).toEqual(["TAB1", "TAB2"])
  // TAB2 is newer, but the session's page (where `handoff()` waits by default) is TAB1.
  const meta = await adapter.identify!({ kind: "chrome", cdp: relay.cdp, browse: "login" })
  if (meta.kind !== "chrome") throw new Error("expected Chrome metadata")
  expect(meta).toEqual({
    kind: "chrome",
    cdp: relay.cdp,
    browse: "login",
    targetID: "TAB1",
    url: "http://127.0.0.1:5191/",
    title: "Entrar · Abacato",
  })
  expect(
    handoffTab(
      [
        { targetId: "A", url: "x" },
        { targetId: "B", url: "y" },
      ],
      undefined,
      "zzz",
    )?.targetId,
  ).toBe("B")
  expect(
    handoffTab(
      [
        { targetId: "A", url: "x" },
        { targetId: "B", url: "y" },
      ],
      "A",
      "y",
    )?.targetId,
  ).toBe("A")
  const probed = (await adapter.probe([entryOf(meta)])).get("chrome:browse:login")
  expect(probed).toEqual({
    status: "running",
    meta: { kind: "chrome", browse: "login", cdp: relay.cdp, targetID: "TAB1", url: meta.url, title: meta.title },
  })
  const shown = JSON.stringify([meta, probed])
  expect(shown).not.toContain("Banco")
  expect(shown).not.toContain(token)
  // The handoff's tab closed: the resource is gone rather than another tab of the session.
  expect((await adapter.probe([entryOf({ ...meta, targetID: "CLOSED" })])).get("chrome:browse:login")?.status).toBe(
    "gone",
  )
  expect(relay.refused).toEqual([])

  // A wrong token: refused by the relay, and no message carries either token.
  await Bun.write(tokenFile, "not-the-token\n")
  try {
    const error = (await adapter.identify!({ kind: "chrome", cdp: relay.cdp, browse: "login" }).catch(
      (e: unknown) => e,
    )) as Error
    expect(error).toBeInstanceOf(Error)
    expect(error.message).not.toContain("not-the-token")
    expect(error.message).not.toContain(token)
    expect(relay.refused.length).toBeGreaterThan(0)
    const fresh = makeChromeAdapter()
    stops.push(() => fresh.close())
    expect((await fresh.probe([entryOf(meta)])).get("chrome:browse:login")?.status).toBe("gone")
  } finally {
    await Bun.write(tokenFile, `${token}\n`)
  }
})

test("the viewer sees and touches only the handoff's tab, through the browser zoom, and can focus it but not navigate", async () => {
  const relay = fakeBrowser({ token })
  stops.push(() => relay.server.stop(true))
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const entry = entryOf({ kind: "chrome", cdp: relay.cdp, browse: "login", targetID: "TAB1" })
  const viewer = watch(adapter, entry)
  await viewer.until(() => viewer.frames.length > 0 && viewer.states.at(-1)?.viewport !== undefined)
  // Alexandre's Chrome at 125 %: frames are 1400 × 771 DIP, the page 1120 × 617 CSS px.
  expect(viewer.states.at(-1)).toMatchObject({
    targetID: "TAB1",
    tabs: [{ id: "TAB1" }],
    viewport: { width: 1120, height: 617 },
  })
  // A new tab of the session (or the other one it has) never shows up.
  relay.event("Target.targetCreated", {
    targetInfo: { targetId: "TAB3", type: "page", title: "Popup", url: "http://127.0.0.1:5191/p" },
  })
  await Bun.sleep(30)
  expect(viewer.states.flatMap((state) => state.tabs.map((tab) => tab.id))).not.toContain("TAB2")
  expect(viewer.states.flatMap((state) => state.tabs.map((tab) => tab.id))).not.toContain("TAB3")

  await adapter.input!(entry, { type: "touch", phase: "began", x: 0.5, y: 0.25 })
  await adapter.input!(entry, { type: "touch", phase: "ended", x: 0.5, y: 0.25 })
  const pressed = relay.sent.find(
    (item) => item.method === "Input.dispatchMouseEvent" && item.params.type === "mousePressed",
  )
  expect(pressed?.params.x).toBeCloseTo(560, 1)
  expect(pressed?.params.y).toBeCloseTo(154.2, 1)
  expect(pressed?.sessionId).toBe("S-TAB1")

  // Navigation is refused by the adapter too (the hub refuses it first), and nothing is sent for it.
  for (const action of ["url", "back", "forward", "reload", "tab"] as const)
    await expect(
      adapter.input!(entry, { type: "navigate", action, url: "https://example.com", target: "TAB2" }),
    ).rejects.toThrow("not_allowed")
  await expect(adapter.input!(entry, { type: "button", button: "back" })).rejects.toThrow("not_allowed")
  await Bun.sleep(20)

  // As browse 0.0.14 behaves: Chrome refuses the activation to the extension and the relay blocks the fallback.
  const forward = (item: { method: string }) =>
    item.method === "Target.activateTarget" || item.method === "Page.bringToFront"
  await expect(adapter.focus!(entry)).rejects.toThrow(
    "O navegador não deixou trazer a aba para a frente (Not allowed; browse blocked Page.bringToFront).",
  )
  expect(relay.sent.filter(forward)).toEqual([
    { method: "Target.activateTarget", params: { targetId: "TAB1" }, sessionId: "S-TAB1" },
    { method: "Page.bringToFront", params: {}, sessionId: "S-TAB1" },
  ])
  // A relay that allows either brings exactly the handoff's tab forward.
  delete relay.refuse["Page.bringToFront"]
  await adapter.focus!(entry)
  delete relay.refuse["Target.activateTarget"]
  const sent = relay.sent.length
  await adapter.focus!(entry)
  expect(relay.sent.slice(sent).filter(forward)).toEqual([
    { method: "Target.activateTarget", params: { targetId: "TAB1" }, sessionId: "S-TAB1" },
  ])
  // Never a navigation, another tab or Alexandre's window.
  const methods = relay.sent.map((item) => item.method)
  expect(methods.filter((method) => /^Page\.(navigate|reload)|^Browser\./.test(method))).toEqual([])
  expect(
    relay.sent.filter((item) => item.method === "Target.attachToTarget").map((item) => item.params.targetId),
  ).toEqual(["TAB1"])

  // The handoff's tab closing ends the stream instead of moving to another tab.
  relay.event("Target.targetDestroyed", { targetId: "TAB1" })
  expect(await viewer.streaming).toBeInstanceOf(Error)
  expect(relay.sent.filter((item) => item.method === "Target.attachToTarget")).toHaveLength(1)
})

test("an unknown handoff tab is not replaced by another; forget closes the connection; errors hide the token", async () => {
  const relay = fakeBrowser({ token })
  stops.push(() => relay.server.stop(true))
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const missing = entryOf({ kind: "chrome", cdp: relay.cdp, browse: "login", targetID: "CLOSED" })
  await expect(adapter.snapshot(missing)).rejects.toThrow("A aba do handoff não está aberta.")
  const entry = entryOf({ kind: "chrome", cdp: relay.cdp, browse: "login", targetID: "TAB1" })
  expect((await adapter.snapshot(entry)).mime).toBe("image/jpeg")
  await adapter.forget!(entry)
  await Bun.sleep(20)
  // The relay's WebSocket URL carries the token: a failed connection never shows it.
  const url = `ws://127.0.0.1:1/devtools/browser/x?opencodeBrowserSessionId=login&opencodeBrowserToken=${token}`
  const error = (await CDP.connect(url, 500).catch((e: unknown) => e)) as Error
  expect(error.message).toContain("ws://127.0.0.1:1/devtools/browser/x")
  expect(error.message).not.toContain(token)
  expect(withoutQuery(`http://user:pass@h:1/p?opencodeBrowserToken=${token}`)).toBe("http://h:1/p")
})
