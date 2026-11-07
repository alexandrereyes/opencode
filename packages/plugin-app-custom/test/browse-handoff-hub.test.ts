import { afterEach, expect, spyOn, test } from "bun:test"
import { Schema } from "effect"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { makeRegistry } from "../src/browser-handoff/registry"
import type { Adapter, Entry } from "../src/resources/adapters/types"
import { allowed, createHub, idFor, label, protocol, sameResource } from "../src/resources/hub/hub"
import { waiting } from "../src/resources/index"
import { externalAddresses, machineID, makeMachine, parsePlatformUUID } from "../src/resources/machine"
import { ResourceProtocol } from "../src/resources/protocol"
import { Resources } from "../src/resources/rpc"
import { HubError, makeHubClient } from "../src/resources/supervisor"

/** The hub side of `docs/browse-handoff-remoto.md`, with a Chrome adapter that stands for the browse relay. */

const jpegPixel = Buffer.from(
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAA//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AN//Z",
  "base64",
)
const platform = "8B2D5C1E-4F3A-4B6C-9D8E-7F6A5B4C3D2E"
const secret = "hub-secret"

function fakeChrome() {
  const inputs: ResourceProtocol.Input[] = []
  const focused: string[] = []
  const forgotten: string[] = []
  const state = { tab: true as boolean, focusFails: false, inputFails: false }
  const adapter: Adapter = {
    kind: "chrome",
    probe: async (entries) => new Map(entries.map((entry) => [entry.id, { status: "running" as const }])),
    snapshot: async () => ({ mime: "image/jpeg", data: new Uint8Array(jpegPixel), width: 1, height: 1 }),
    stream: async (_entry, sink, signal) => {
      sink.hello({ format: "jpeg", width: 1, height: 1 })
      sink.frame(new Uint8Array(jpegPixel), { capturedAt: 1 })
      await new Promise((resolve) => signal.addEventListener("abort", resolve))
    },
    input: async (_entry, event) => {
      if (state.inputFails) throw new Error("Input.insertText failed")
      inputs.push(event)
    },
    identify: async (meta) => {
      if (meta.kind !== "chrome" || !meta.browse) return meta
      if (!state.tab) throw new Error("A sessão do browse não tem aba aberta.")
      return { ...meta, targetID: "TAB1", url: "http://127.0.0.1:5191/", title: "Entrar · Abacato" }
    },
    focus: async (entry) => {
      if (state.focusFails) throw new Error("browse blocked Target.activateTarget")
      focused.push(entry.id)
    },
    forget: async (entry) => void forgotten.push(entry.id),
  }
  return { adapter, inputs, focused, forgotten, state }
}

const servers: { stop: (force?: boolean) => unknown }[] = []
const directories: string[] = []
afterEach(async () => {
  servers.splice(0).forEach((server) => server.stop(true))
  await Promise.all(directories.splice(0).map((directory) => fs.rm(directory, { recursive: true, force: true })))
})

async function serve(machine = async (_cdp: string | undefined) => machineID(platform) as string | undefined) {
  const fake = fakeChrome()
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "browse-handoff-hub-"))
  directories.push(directory)
  const file = path.join(directory, "resources.json")
  const hub = createHub({
    adapters: { "ios-simulator": fake.adapter, "android-emulator": fake.adapter, chrome: fake.adapter },
    secret,
    file,
    machine,
  })
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: hub.fetch, websocket: hub.websocket })
  servers.push(server)
  await Bun.write(
    path.join(directory, "hub.json"),
    JSON.stringify({ protocol, pid: process.pid, port: server.port, secret }),
  )
  const client = makeHubClient({ state: directory })
  return { hub, server, fake, client, file, directory }
}

const register = {
  kind: "chrome" as const,
  meta: { kind: "chrome" as const, cdp: "http://127.0.0.1:19988", browse: "login" },
  purpose: "Entre com a senha",
  owner: { sessionID: "ses_child", rootSessionID: "ses_root", agent: "build" },
  used: true,
  capabilities: { navigation: false, tabs: false, focus: true },
  handoff: { id: "brw_1", sessionID: "ses_child", message: "Entre com a senha", since: 5 },
}

function socket(url: string) {
  const ws = new WebSocket(url)
  ws.binaryType = "arraybuffer"
  const messages: (ResourceProtocol.ServerMessage | Uint8Array)[] = []
  const closed = new Promise<void>((resolve) => ws.addEventListener("close", () => resolve()))
  ws.onmessage = (event) =>
    void messages.push(typeof event.data === "string" ? JSON.parse(event.data) : new Uint8Array(event.data))
  const next = async (predicate: (message: ResourceProtocol.ServerMessage) => boolean) => {
    const deadline = Date.now() + 5_000
    while (Date.now() < deadline) {
      const found = messages.find(
        (message): message is ResourceProtocol.ServerMessage => !(message instanceof Uint8Array) && predicate(message),
      )
      if (found) return found
      await Bun.sleep(10)
    }
    throw new Error(`message not received; got ${JSON.stringify(messages.filter((m) => !(m instanceof Uint8Array)))}`)
  }
  return { ws, messages, next, closed, opened: new Promise((resolve) => (ws.onopen = resolve)) }
}

test("a handoff's resource has its own ID, label, capabilities, handoff and machine, and is never persisted", async () => {
  const { hub, client, file } = await serve()
  const resource = await client.upsert(register)
  expect(resource).toMatchObject({
    id: "chrome:browse:login",
    kind: "chrome",
    label: "Navegador · 127.0.0.1:5191",
    purpose: "Entre com a senha",
    owner: { sessionID: "ses_child", rootSessionID: "ses_root", agent: "build" },
    meta: { kind: "chrome", cdp: "http://127.0.0.1:19988", browse: "login", targetID: "TAB1" },
    capabilities: { navigation: false, tabs: false, focus: true },
    handoff: {
      id: "brw_1",
      sessionID: "ses_child",
      message: "Entre com a senha",
      since: 5,
      machine: machineID(platform),
    },
  })
  expect(Schema.decodeUnknownSync(Resources.Resource)(resource)).toBeDefined()
  expect((await client.list()).resources.map((item) => item.id)).toEqual(["chrome:browse:login"])
  // Another session of the same relay is another resource.
  expect(sameResource(register.meta, { ...register.meta, browse: "other" })).toBe(false)
  expect(sameResource(register.meta, { kind: "chrome", cdp: register.meta.cdp })).toBe(false)
  expect(idFor({ kind: "chrome", cdp: "http://127.0.0.1:19988", browse: "x" })).toBe("chrome:browse:x")
  expect(label({ meta: { kind: "chrome", browse: "x" } })).toBe("Navegador · x")
  // A plain resource registered meanwhile is persisted; the handoff's never is.
  hub.upsert({ kind: "chrome", meta: { kind: "chrome", session: "default" } })
  const deadline = Date.now() + 5_000
  while (!(await Bun.file(file).exists()) && Date.now() < deadline) await Bun.sleep(20)
  await Bun.sleep(50)
  const stored: Entry[] = await Bun.file(file).json()
  expect(stored.map((entry) => entry.id)).toEqual(["chrome:default"])
  hub.close()
})

test("without the handoff's tab, or without a relay on loopback that only this Mac reaches, it is refused or anonymous", async () => {
  const { client, fake } = await serve(async () => undefined)
  fake.state.tab = false
  const refused = await client.upsert(register).catch((error: unknown) => error)
  expect(refused).toBeInstanceOf(HubError)
  expect((refused as HubError).reason).toBe("failed")
  expect((await client.list()).resources).toEqual([])
  fake.state.tab = true
  expect((await client.upsert(register)).handoff).toEqual({
    id: "brw_1",
    sessionID: "ses_child",
    message: "Entre com a senha",
    since: 5,
  })
})

test("the machine identity needs this Mac's UUID and a relay that refuses every outside address", async () => {
  expect(parsePlatformUUID(`  "IOPlatformSerialNumber" = "X"\n  "IOPlatformUUID" = "${platform}"\n`)).toBe(platform)
  expect(parsePlatformUUID("nothing")).toBeUndefined()
  const tried: string[] = []
  const open = new Set<string>()
  const machine = makeMachine({
    platformUUID: async () => platform,
    addresses: () => ["192.168.0.10", "2804:14c::1"],
    accepts: async (address, port) => {
      tried.push(`${address}:${port}`)
      return open.has(address)
    },
  })
  expect(await machine("http://127.0.0.1:19988")).toBe(machineID(platform))
  expect(tried).toEqual(["192.168.0.10:19988", "2804:14c::1:19988"])
  // `browse set hostname 0.0.0.0`: other machines could pair their browsers.
  open.add("192.168.0.10")
  expect(await machine("http://127.0.0.1:19988")).toBeUndefined()
  open.clear()
  // A relay that is not on loopback, or a machine that is no Mac, has no identity to offer.
  expect(await machine("http://10.0.0.5:19988")).toBeUndefined()
  expect(await machine(undefined)).toBeUndefined()
  expect(await makeMachine({ platformUUID: async () => undefined, addresses: () => [] })("http://127.0.0.1:1")).toBe(
    undefined,
  )
  // Link-local IPv6 needs a scope and is never how another machine pairs; loopback is internal.
  expect(
    externalAddresses({
      lo0: [{ address: "127.0.0.1", family: "IPv4", internal: true, netmask: "", mac: "", cidr: null }],
      en0: [
        { address: "fe80::1", family: "IPv6", internal: false, netmask: "", mac: "", cidr: null, scopeid: 4 },
        { address: "192.168.0.10", family: "IPv4", internal: false, netmask: "", mac: "", cidr: null },
      ],
    }),
  ).toEqual(["192.168.0.10"])
})

test("navigation and tab switching are refused with not_allowed and never applied; the rest goes through", async () => {
  const { hub, server, fake, client } = await serve()
  const resource = await client.upsert(register)
  await client.control(resource.id, "take")
  const base = `ws://127.0.0.1:${server.port}/resources/${encodeURIComponent(resource.id)}`
  const viewer = socket(`${base}/stream?ticket=${hub.ticket(resource.id, "control")?.ticket}`)
  await viewer.opened
  await viewer.next((message) => message.type === "hello")
  const refused: ResourceProtocol.Input[] = [
    { type: "navigate", action: "url", url: "https://example.com" },
    { type: "navigate", action: "back" },
    { type: "navigate", action: "forward" },
    { type: "navigate", action: "reload" },
    { type: "navigate", action: "tab", target: "TAB2" },
    { type: "button", button: "back" },
  ]
  for (const event of refused) {
    viewer.ws.send(
      JSON.stringify({ type: "input", events: [{ type: "touch", phase: "began", x: 0.1, y: 0.1 }, event] }),
    )
  }
  await Bun.sleep(50)
  expect(viewer.messages.filter((m) => !(m instanceof Uint8Array) && m.type === "error")).toEqual(
    refused.map(() => ({ type: "error", message: "not_allowed" })),
  )
  // The touch of a refused batch is not applied either.
  expect(fake.inputs).toEqual([])
  viewer.ws.send(JSON.stringify({ type: "input", events: [{ type: "touch", phase: "began", x: 0.5, y: 0.5 }] }))
  const http = await fetch(
    `http://127.0.0.1:${server.port}/resources/${encodeURIComponent(resource.id)}/input?ticket=${hub.ticket(resource.id, "control")?.ticket}`,
    {
      method: "POST",
      body: JSON.stringify({ events: [{ type: "navigate", action: "url", url: "https://example.com" }] }),
    },
  )
  expect(http.status).toBe(409)
  expect(await http.json()).toEqual({ error: "not_allowed" })
  const deadline = Date.now() + 5_000
  while (fake.inputs.length < 1 && Date.now() < deadline) await Bun.sleep(10)
  expect(fake.inputs).toEqual([{ type: "touch", phase: "began", x: 0.5, y: 0.5 }])
  // Other resources keep every input.
  expect(allowed(undefined, { type: "navigate", action: "url", url: "x" })).toBe(true)
  expect(allowed({ navigation: false }, { type: "navigate", action: "tab", target: "x" })).toBe(true)
  expect(allowed({ tabs: false }, { type: "navigate", action: "tab", target: "x" })).toBe(false)
  viewer.ws.close()
  hub.close()
})

test("typed text never reaches a log, not even when it fails", async () => {
  const { hub, server, fake, client } = await serve()
  const resource = await client.upsert(register)
  await client.control(resource.id, "take")
  const lines: string[] = []
  const spies = (["log", "info", "warn", "error", "debug"] as const).map((method) =>
    spyOn(console, method).mockImplementation((...args: unknown[]) => void lines.push(args.map(String).join(" "))),
  )
  try {
    const viewer = socket(
      `ws://127.0.0.1:${server.port}/resources/${encodeURIComponent(resource.id)}/stream?ticket=${hub.ticket(resource.id, "control")?.ticket}`,
    )
    await viewer.opened
    viewer.ws.send(JSON.stringify({ type: "input", events: [{ type: "text", text: "senha-falsa-123" }] }))
    const deadline = Date.now() + 5_000
    while (fake.inputs.length < 1 && Date.now() < deadline) await Bun.sleep(10)
    fake.state.inputFails = true
    viewer.ws.send(JSON.stringify({ type: "input", events: [{ type: "text", text: "senha-falsa-456" }] }))
    expect(await viewer.next((message) => message.type === "error")).toEqual({ type: "error", message: "input_failed" })
    viewer.ws.close()
  } finally {
    spies.forEach((spy) => spy.mockRestore())
  }
  expect(fake.inputs).toEqual([{ type: "text", text: "senha-falsa-123" }])
  expect(lines.join("\n")).not.toContain("senha-falsa")
  expect(lines.some((line) => line.includes("input failed"))).toBe(true)
  hub.close()
})

test("ending a handoff's resource ends its viewers with the reason, releases control quietly and waits to announce", async () => {
  const { hub, server, fake, client } = await serve()
  const resource = await client.upsert(register)
  await client.control(resource.id, "take")
  await hub.claim(0)
  const base = `ws://127.0.0.1:${server.port}/resources/${encodeURIComponent(resource.id)}/stream`
  const watching = socket(`${base}?ticket=${hub.ticket(resource.id, "view")?.ticket}`)
  const controlling = socket(`${base}?ticket=${hub.ticket(resource.id, "control")?.ticket}`)
  await Promise.all([watching.opened, controlling.opened])
  await watching.next((message) => message.type === "hello")
  await controlling.next((message) => message.type === "hello")

  await client.finish(resource.id, Resources.handoffEndReasons.completed)
  for (const viewer of [watching, controlling]) {
    expect(await viewer.next((message) => message.type === "end")).toEqual({ type: "end", reason: "handoff_completed" })
    await viewer.closed
  }
  // No hand-back notice for the agent, and no resources event until the plugin announces the handoff's end first.
  expect(await hub.claim(0)).toEqual([])
  expect(fake.forgotten).toEqual([resource.id])
  for (const call of [
    () => client.get(resource.id),
    () => client.control(resource.id, "take"),
    () => client.ticket(resource.id, "view"),
    () => client.snapshot(resource.id),
    () => client.focus(resource.id),
  ])
    expect(((await call().catch((error: unknown) => error)) as HubError).reason).toBe("not_found")
  await client.announce([resource.id])
  expect(await hub.claim(0)).toEqual([{ type: "changed", ids: [resource.id] }])
  // Ending it again finds nothing; an unknown reason is refused.
  expect(((await client.finish(resource.id, "handoff_failed").catch((e: unknown) => e)) as HubError).reason).toBe(
    "not_found",
  )
  const again = await client.upsert(register)
  const bad = await fetch(`http://127.0.0.1:${server.port}/admin/resources/${encodeURIComponent(again.id)}/end`, {
    method: "POST",
    headers: { authorization: `Bearer ${secret}` },
    body: JSON.stringify({ reason: "ended" }),
  })
  expect(bad.status).toBe(400)
  hub.close()
})

test("focus: only a handoff's resource, only while it waits, failed when the relay refuses", async () => {
  const { hub, fake, client } = await serve()
  const resource = await client.upsert(register)
  await client.focus(resource.id)
  expect(fake.focused).toEqual([resource.id])
  fake.state.focusFails = true
  const failed = (await client.focus(resource.id).catch((error: unknown) => error)) as HubError
  expect(failed.reason).toBe("failed")
  // The relay's message reaches the app, never a token.
  expect(failed.message).toBe("browse blocked Target.activateTarget")
  const plain = hub.upsert({ kind: "chrome", meta: { kind: "chrome", session: "default" } })
  expect(((await client.focus(plain.id).catch((error: unknown) => error)) as HubError).reason).toBe("unsupported")
  // The plugin offers it only while the registry still has the handoff waiting with this resource.
  const registry = makeRegistry()
  expect(waiting(resource, registry)).toBe(false)
  registry.add({
    id: "brw_1",
    sessionID: "ses_child",
    callID: "call_1",
    messageID: "msg_1",
    message: "Entre",
    since: 5,
    resourceID: resource.id,
    waiting: false,
    owner: {},
    input: {},
  })
  expect(waiting(resource, registry)).toBe(false)
  registry.reveal("brw_1")
  expect(waiting(resource, registry)).toBe(true)
  expect(waiting({ ...resource, handoff: { ...resource.handoff!, id: "brw_2" } }, registry)).toBe(false)
  hub.close()
})
