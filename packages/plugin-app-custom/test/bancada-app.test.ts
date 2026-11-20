import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import { createCore, type Machine } from "../src/bancada/daemon/core"
import type { Launcher } from "../src/bancada/daemon/executor"
import { makeChanges, makeSurface, server } from "../src/bancada/daemon/surface"
import type { BancadaProtocol } from "../src/bancada/protocol"

// The instant of the fixtures (`docs/bancada.md`, "App surface"): one world, two servers, every number of the mocks.
// The views are the real ones (`surface.ts`) over the state each server keeps; `BANCADA_FIXTURES=1` writes the
// normative files in `docs/bancada/`, otherwise the test checks them.
const now = 1_795_092_060_000
const minute = 60_000
const mac = { machineID: "m-mac", instanceID: "9b2e7c60-1d4f-4e0a-8a3b-5c6d7e8f9a10", name: "Mac de Alexandre" }
const linux = { machineID: "m-linux", instanceID: "3f0c1f4e-6c0b-4a57-9d55-0a4f3b1c9e21", name: "Linux BRS" }
const idle: Launcher = {
  start: async () => {},
  status: async () => ({ state: "rodando" }),
  cancel: async () => {},
  stop: async () => {},
  reap: async () => {},
  held: () => false,
  cleanup: async () => {},
}
const code = { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false }
const spec = (
  part: string,
  label: string,
  platform: "android" | "ios",
  min = 1,
  max = min,
): BancadaProtocol.PartSpec => ({
  part,
  label,
  platform,
  needs: [platform],
  device: {},
  devices: { min, max },
  exclusive: [],
  unsafe: false,
  build: true,
  args: [],
})
const android = spec("android", "Android", "android")
const androids = spec("android", "Android", "android", 2)
const ios = spec("ios", "iOS", "ios")
const servidor = { ...spec("android-servidor", "Android + servidor", "android"), exclusive: ["abacato:servidor-dev"] }
const emulator = {
  kind: "android-emulador",
  id: "bancada-a36-ga-arm64-estoque-1",
  resourceID: "android-emulator:bancada-a36-ga-arm64-estoque-1",
}

/** Who asked: a server, its session and the family's root, with the titles of the moment of the request. */
const origin = (at: typeof mac, sessionID: string, rootTitle: string, child?: string) => ({
  instanceID: at.instanceID,
  machineID: at.machineID,
  name: at.name,
  sessionID: child ? "ses_bancada_child" : sessionID,
  rootSessionID: sessionID,
  rootTitle,
  ...(child ? { sessionTitle: child } : {}),
})
type Part = {
  spec: BancadaProtocol.PartSpec
  state: BancadaProtocol.PartState
  machine?: typeof mac
  since: number
  position?: number
  etaMs?: number
  reason?: BancadaProtocol.Reason
  devices?: (typeof emulator)[]
}
const fila = { code: "fila" as const, text: "na fila" }
/** The requests of the instant, in the order of the plan's table. */
const requests: { job: string; origin: ReturnType<typeof origin>; created: number; parts: Part[] }[] = [
  {
    job: "j-0142ckt1",
    origin: origin(mac, "ses_bancada_root", "Fluxo do checkout"),
    created: now - 5 * minute,
    parts: [{ spec: android, state: "rodando", machine: mac, since: now - 4 * minute, devices: [emulator] }],
  },
  {
    job: "j-0143ckt2",
    origin: origin(mac, "ses_bancada_root", "Fluxo do checkout", "Testar o checkout"),
    created: now - 1 * minute,
    parts: [
      { spec: androids, state: "na_fila", since: now - 1 * minute, position: 3, etaMs: 4 * minute, reason: fila },
    ],
  },
  {
    job: "j-7qk2m9xa",
    origin: origin(mac, "ses_bancada_audio", "Transcrição de áudio"),
    created: now - 7 * minute,
    parts: [
      { spec: android, state: "rodando", machine: mac, since: now - 6 * minute },
      { spec: ios, state: "rodando", machine: mac, since: now - 2 * minute },
    ],
  },
  {
    job: "j-pm3nt0a1",
    origin: origin(linux, "ses_bancada_pedido", "Polimento pedido"),
    created: now - 12 * minute,
    parts: [{ spec: android, state: "rodando", machine: linux, since: now - 11 * minute }],
  },
  {
    job: "j-cat4g0a1",
    origin: origin(mac, "ses_bancada_catalogo", "Catálogo"),
    created: now - 5 * minute,
    parts: [{ spec: android, state: "na_fila", since: now - 5 * minute, position: 1, etaMs: 3 * minute, reason: fila }],
  },
  {
    job: "j-ass1st3a",
    origin: origin(linux, "ses_bancada_assistente", "Assistente - ações"),
    created: now - 4 * minute,
    parts: [
      {
        spec: servidor,
        state: "na_fila",
        since: now - 4 * minute,
        reason: { code: "trava", detail: "abacato:servidor-dev", text: "aguardando trava servidor-dev" },
      },
    ],
  },
  {
    job: "j-emp2st1m",
    origin: origin(mac, "ses_bancada_emprestimo", "Empréstimo de produto"),
    created: now - 3 * minute,
    parts: [
      {
        spec: ios,
        state: "na_fila",
        since: now - 3 * minute,
        position: 2,
        etaMs: 7 * minute,
        reason: { code: "orcamento", text: "aguardando um Mac" },
      },
    ],
  },
]

function world() {
  const machine = (at: typeof mac, hub: boolean): Machine => ({
    machineID: at.machineID,
    instanceID: at.instanceID,
    name: at.name,
    platform: at === mac ? "darwin" : "linux",
    hub,
    speed: "normal",
    capabilities: {},
    capacity: { memMb: 64_000, cpuMilli: 16_000, builds: 1, android: 4, ios: 2 },
    ...(at === mac
      ? {
          phones: [
            {
              alias: "poco",
              name: "POCO X7",
              id: "IBHUYT85ZTYH5XDM",
              platform: "android" as const,
              transport: "usb" as const,
              tags: [],
              realAccounts: false,
              policy: "reservavel" as const,
            },
          ],
        }
      : {}),
  })
  const make = (at: typeof mac, hub: boolean) => {
    const db = new Database(":memory:")
    const core = createCore({
      db,
      now: () => now,
      random: () => crypto.randomUUID(),
      machine: machine(at, hub),
      launcher: idle,
      log: () => {},
    })
    return { db, core }
  }
  const hub = make(linux, true)
  const own = make(mac, false)
  // The hub: both machines, and every request's parts as its queue holds them.
  for (const at of [mac, linux])
    hub.db.run(
      "INSERT OR REPLACE INTO hub_machine (machine_id, instance_id, name, platform, state, protocol, last_sync_at) VALUES (?, ?, ?, ?, 'ok', 1, ?)",
      [at.machineID, at.instanceID, at.name, at === mac ? "darwin" : "linux", now],
    )
  for (const request of requests) {
    hub.db.run(
      "INSERT INTO hub_job (id, origin_machine, origin, code, state, created_at) VALUES (?, ?, ?, ?, 'aberto', ?)",
      [request.job, request.origin.machineID, JSON.stringify(request.origin), JSON.stringify(code), request.created],
    )
    request.parts.forEach((part, index) =>
      hub.db.run(
        "INSERT INTO hub_part (job_id, part, idx, spec, state, attempt_n, machine_id, devices_granted, devices, waiting, since, offered_at, acked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
          request.job,
          part.spec.part,
          index,
          JSON.stringify(part.spec),
          part.state,
          part.machine ? 1 : 0,
          part.machine?.machineID ?? null,
          part.machine ? part.spec.devices.min : null,
          part.devices ? JSON.stringify(part.devices) : null,
          part.state === "na_fila"
            ? JSON.stringify({
                reason: part.reason,
                ...(part.position ? { position: part.position } : {}),
                ...(part.etaMs ? { etaMs: part.etaMs } : {}),
              })
            : null,
          part.since,
          part.machine ? part.since : null,
          part.machine ? part.since : null,
        ],
      ),
    )
  }
  // The Mac: its sessions' requests as the hub last told it, the POCO X7 its root holds, and the hub's catalog.
  for (const request of requests.filter((item) => item.origin.machineID === mac.machineID)) {
    const view = Object.fromEntries(
      request.parts.map((part) => [
        part.spec.part,
        {
          state: part.state,
          attempt: part.machine ? 1 : 0,
          ...(part.machine ? { machine: part.machine } : {}),
          ...(part.position ? { position: part.position } : {}),
          ...(part.etaMs ? { etaMs: part.etaMs } : {}),
          ...(part.reason ? { reason: part.reason } : {}),
          ...(part.devices ? { devices: part.devices } : {}),
          since: part.since,
        },
      ]),
    )
    own.db.run(
      "INSERT INTO job (id, session_id, root_session_id, origin, code, parts, scope, state, view, created_at) VALUES (?, ?, ?, ?, ?, ?, 'hub', 'na_fila', ?, ?)",
      [
        request.job,
        request.origin.sessionID,
        request.origin.rootSessionID,
        JSON.stringify(request.origin),
        JSON.stringify(code),
        JSON.stringify(request.parts.map((part) => part.spec)),
        JSON.stringify(view),
        request.created,
      ],
    )
  }
  own.db.run(
    "INSERT INTO grant_mirror (hold, session_id, root_session_id, machine_id, target, state, machine_name, device, expires_at, requested_at, updated_at) VALUES ('r-poc0x7a1', 'ses_bancada_root', 'ses_bancada_root', ?, ?, 'concedida', ?, ?, ?, ?, ?)",
    [
      mac.machineID,
      JSON.stringify({ kind: "fisico", device: "poco" }),
      mac.name,
      JSON.stringify({ id: "IBHUYT85ZTYH5XDM" }),
      now + 52 * minute,
      now - 8 * minute,
      now - 8 * minute,
    ],
  )
  return { hub, own }
}

async function fixture(name: string, value: unknown) {
  const file = new URL(`../docs/bancada/${name}.json`, import.meta.url)
  if (process.env.BANCADA_FIXTURES === "1") await Bun.write(file, `${JSON.stringify(value, null, 2)}\n`)
  expect(value).toEqual(await Bun.file(file).json())
}

describe("the apps' surface at the instant of the fixtures", () => {
  test("session for the root of Fluxo do checkout: the test's emulator, then the POCO X7; the subagent's wait", async () => {
    const it = world()
    const view = it.own.core.surface.session("ses_bancada_root")
    await fixture("session-a1-b1", view)
    expect(view).toMatchObject({
      now,
      hub: "ok",
      counts: { using: 2, waiting: 1 },
      using: [
        {
          kind: "android-emulator",
          kindLabel: "Emulador Android",
          resourceID: emulator.resourceID,
          viewer: { instanceID: mac.instanceID, resourceID: emulator.resourceID },
          machine: { instanceID: mac.instanceID, name: mac.name, short: "MA" },
          by: { sessionID: "ses_bancada_root", root: true },
          use: { type: "job", job: "j-0142ckt1", teste: "android", state: "rodando", since: now - 4 * minute },
        },
        {
          kind: "android-device",
          name: "POCO X7",
          resourceID: "android-device:IBHUYT85ZTYH5XDM",
          use: { type: "hold", since: now - 8 * minute, expiresAt: now + 52 * minute },
        },
      ],
      waiting: [
        {
          what: { kind: "android-emulator", count: { min: 2, max: 2 }, label: "2 emuladores Android" },
          by: { sessionID: "ses_bancada_child", title: "Testar o checkout", root: false },
          queue: { job: "j-0143ckt2" },
          position: 3,
          etaMs: 4 * minute,
          reason: fila,
          since: now - minute,
        },
      ],
      members: [
        { sessionID: "ses_bancada_root", root: true, using: 2 },
        { sessionID: "ses_bancada_child", root: false, using: 0, waiting: { count: 1, position: 3, reason: fila } },
      ],
    })
    expect((view.using[0] as Record<string, unknown>).name).toBeUndefined()
    expect((view.using[1] as Record<string, unknown>).viewer).toBeUndefined()
  })

  test("queue on the hub: running by last start, waiting by arrival; counts and machines agree; the same wait as session", async () => {
    const it = world()
    const queue = it.hub.core.surface.queue()
    await fixture("queue-c2-d1-f3", queue)
    expect(queue.now).toBe(now)
    expect(queue.scope).toBe("all")
    expect(queue.counts).toEqual({ running: 4, waiting: 4 })
    expect(queue.running.map((group) => group.job)).toEqual(["j-0142ckt1", "j-7qk2m9xa", "j-pm3nt0a1"])
    expect(queue.waiting.map((group) => group.job)).toEqual(["j-cat4g0a1", "j-ass1st3a", "j-emp2st1m", "j-0143ckt2"])
    expect(queue.machines.map((item) => [item.server.short, item.running])).toEqual([
      ["LB", 1],
      ["MA", 3],
    ])
    expect(queue.machines.reduce((sum, item) => sum + item.running, 0)).toBe(queue.counts.running)
    // The B1 → D1 link: the subagent's wait is the same group, place and estimate in both.
    const session = it.own.core.surface.session("ses_bancada_root")
    const wait = session.waiting[0] as { queue: { job: string }; position: number; etaMs: number }
    const group = queue.waiting.find((item) => item.job === wait.queue.job)!
    expect(group.parts[0]).toMatchObject({ position: wait.position, etaMs: wait.etaMs })
    expect(group.session).toEqual({
      server: server(mac.instanceID, mac.name),
      sessionID: "ses_bancada_child",
      rootSessionID: "ses_bancada_root",
      title: "Fluxo do checkout",
      by: "Testar o checkout",
    })
    expect(queue.waiting[1]!.parts[0]).toEqual({
      teste: "android-servidor",
      label: "Android + servidor",
      platform: "android",
      reason: { code: "trava", detail: "abacato:servidor-dev", text: "aguardando trava servidor-dev" },
      since: now - 4 * minute,
    })
  })

  test("queue seen by the Mac with the hub out: its own requests, waiting for the hub, no places", async () => {
    const it = world()
    const local = makeSurface({
      db: it.own.db,
      now: () => now,
      self: () => mac,
      hubState: () => "unavailable",
      isHub: false,
      holds: () => [],
      phone: () => undefined,
      machine: (machineID) => (machineID === mac.machineID ? server(mac.instanceID, mac.name) : undefined),
      alerts: () => [],
    }).queue()
    await fixture("queue-local", local)
    expect(local).toMatchObject({ scope: "local", hub: "unavailable", counts: { running: 3, waiting: 3 } })
    expect(local.running.map((group) => group.job)).toEqual(["j-0142ckt1", "j-7qk2m9xa"])
    expect(local.waiting.map((group) => group.job)).toEqual(["j-cat4g0a1", "j-emp2st1m", "j-0143ckt2"])
    expect(local.waiting.flatMap((group) => group.parts)).toEqual(
      local.waiting
        .flatMap((group) => group.parts)
        .map((part) => ({
          teste: part.teste,
          label: part.label,
          platform: part.platform,
          reason: { code: "aguardando_hub", text: "aguardando o hub" },
          since: part.since,
        })),
    )
    expect(local.machines).toEqual([{ server: server(mac.instanceID, mac.name), state: "ok", running: 3 }])
  })

  test("changed: when a family's view or the queue changes, not for an estimate alone, at most once a second", () => {
    const state = {
      at: now,
      queue: { a: 1, etaMs: 1 },
      session: { b: 1 },
      alerts: [] as { id: string; kind: string; text: string }[],
    }
    const next = makeChanges({
      now: () => state.at,
      queue: () => state.queue,
      session: () => state.session,
      roots: () => ["ses_r"],
      alerts: () => state.alerts,
    })
    expect(next()).toEqual({ sessions: ["ses_r"], queue: true, alerts: [] })
    state.at += 2_000
    state.queue = { a: 1, etaMs: 9 }
    expect(next()).toBeUndefined()
    state.queue = { a: 2, etaMs: 9 }
    expect(next()).toEqual({ sessions: [], queue: true, alerts: [] })
    // Another change within the second waits for it.
    state.queue = { a: 3, etaMs: 9 }
    state.at += 500
    expect(next()).toBeUndefined()
    state.at += 600
    expect(next()).toEqual({ sessions: [], queue: true, alerts: [] })
    state.at += 2_000
    state.alerts = [{ id: "x", kind: "hub", text: "o hub não responde" }]
    state.session = { b: 2 }
    expect(next()).toEqual({
      sessions: ["ses_r"],
      queue: false,
      alerts: [{ id: "x", kind: "hub", text: "o hub não responde" }],
    })
  })
})
