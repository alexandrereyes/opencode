import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import { createCore } from "../src/bancada/daemon/core"
import type { Launcher } from "../src/bancada/daemon/executor"
import { BancadaProtocol } from "../src/bancada/protocol"

const code = { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false }
const origin = { instanceID: "i-Mac", machineID: "m-Mac", name: "Mac", sessionID: "ses_a", rootSessionID: "ses_a" }
const spec = (part: string, more: Partial<BancadaProtocol.PartSpec> = {}): BancadaProtocol.PartSpec => ({
  part,
  label: part,
  platform: "android",
  needs: ["android"],
  device: {},
  devices: { min: 1, max: 1 },
  exclusive: [],
  unsafe: false,
  build: true,
  args: [],
  ...more,
})
const idle: Launcher = {
  start: async () => {},
  status: async () => ({ state: "rodando" }),
  cancel: async () => {},
  stop: async () => {},
  reap: async () => {},
  held: () => false,
  cleanup: async () => {},
}
const outcome = (verdict: BancadaProtocol.Outcome["verdict"], planned: string[], passed: string[]) => ({
  verdict,
  planned,
  scenarios: passed.map((id) => ({ id, result: "passou" as const })),
  lost: planned.filter((id) => !passed.includes(id)),
  approved: verdict === "aprovado",
})

/**
 * A hub (which takes no part itself) and a Mac written by hand: each `call` is one `sync` of the Mac, with its
 * messages, its pulse (what it runs) and its acknowledgement of everything the hub sent before. The clock moves by hand.
 */
function harness() {
  const clock = { now: 1_000_000 }
  const db = new Database(":memory:")
  let n = 0
  const hub = createCore({
    db,
    now: () => clock.now,
    random: () => `id-${++n}`,
    log: () => {},
    launcher: idle,
    machine: {
      machineID: "m-Linux",
      instanceID: "i-Linux",
      name: "Linux",
      platform: "linux",
      hub: true,
      speed: "normal",
      capabilities: {},
      capacity: { memMb: 0, cpuMilli: 0, builds: 0, android: 0, ios: 0 },
    },
  })
  const mac = {
    stream: "mac-stream",
    seq: 0,
    pulse: 0,
    outbox: [] as { seq: number; body: BancadaProtocol.FromMachine }[],
    base: 0,
    hub: null as BancadaProtocol.Ack,
  }
  const inbox: BancadaProtocol.FromHub[] = []
  const call = (
    messages: BancadaProtocol.FromMachine[] = [],
    running: BancadaProtocol.Pulse["running"] = [],
    more: { pulse?: number; free?: Partial<BancadaProtocol.Vector>; state?: BancadaProtocol.Pulse["state"] } = {},
  ) => {
    messages.forEach((body) => mac.outbox.push({ seq: ++mac.seq, body }))
    const output = hub.sync({
      protocol: BancadaProtocol.version,
      machineID: "m-Mac",
      instanceID: "i-Mac",
      name: "Mac",
      out: { stream: mac.stream, base: mac.base, messages: [...mac.outbox] },
      ack: mac.hub,
      pulse: {
        seq: more.pulse ?? ++mac.pulse,
        state: more.state ?? "ok",
        free: { memMb: 64_000, cpuMilli: 16_000, builds: 2, android: 2, ios: 0, ...more.free },
        brake: false,
        presence: false,
        running,
      },
      waitMs: 0,
    })
    if (output.ack) {
      mac.outbox = mac.outbox.filter((message) => message.seq > output.ack!.seq)
      mac.base = output.ack.seq
    }
    const fresh = output.out.messages.filter((message) => message.seq > (mac.hub?.seq ?? 0))
    if (output.out.messages.length) mac.hub = { stream: output.out.stream, seq: output.out.messages.at(-1)!.seq }
    const bodies = fresh.map((message) => message.body)
    inbox.push(...bodies)
    return bodies
  }
  const later = async (ms: number) => {
    clock.now += ms
    await hub.tick()
  }
  const part = (job: string, name: string) =>
    db
      .query<
        {
          state: string
          attempt_n: number
          held_state: string | null
          outcome: string | null
          only_scenarios: string | null
        },
        [string, string]
      >("SELECT state, attempt_n, held_state, outcome, only_scenarios FROM hub_part WHERE job_id = ? AND part = ?")
      .get(job, name)
  const offers = () => inbox.filter((body) => body.type === "offer") as (typeof BancadaProtocol.Offer.Type)[]
  const cancels = () => inbox.filter((body) => body.type === "attempt.cancel")
  const hello: BancadaProtocol.FromMachine = {
    type: "hello",
    platform: "darwin",
    capabilities: { android: {}, "android-fisico": {} },
    speed: "normal",
  }
  const submit = (job: string, parts: BancadaProtocol.PartSpec[], session = "ses_a"): BancadaProtocol.FromMachine => ({
    type: "submit",
    job,
    origin: { ...origin, sessionID: session, rootSessionID: session },
    code,
    parts,
    createdAt: clock.now,
  })
  return { clock, db, hub, call, later, part, offers, cancels, inbox, hello, submit }
}

const accept = (job: string, part: string, attempt = 1): BancadaProtocol.FromMachine => ({
  type: "offer.reply",
  job,
  part,
  attempt,
  accepted: true,
  devices: 1,
})
const report = (
  job: string,
  part: string,
  attempt: number,
  state: BancadaProtocol.AttemptState,
  result?: BancadaProtocol.Outcome,
): BancadaProtocol.FromMachine => ({
  type: "attempt",
  job,
  part,
  attempt,
  state,
  ...(result ? { outcome: result } : {}),
})
const phone = spec("celular", { needs: ["android-fisico"], unsafe: true })

describe("queue on the hub", () => {
  test("an offer the machine received and did not answer for 30 s is withdrawn: cancelled there, offered again", async () => {
    const it = harness()
    expect(it.call([it.hello, it.submit("j-aaaaaaaa", [spec("android")])])).toContainEqual(
      expect.objectContaining({ type: "offer", attempt: 1 }),
    )
    // The machine acknowledges the offer and keeps calling, without a reply.
    it.call()
    await it.later(1_000)
    it.call()
    await it.later(29_000)
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "oferecido", attempt_n: 1 })
    await it.later(1_000)
    expect(it.call()).toEqual([
      expect.objectContaining({ type: "attempt.cancel", attempt: 1, reason: "oferta retirada" }),
      expect.objectContaining({ type: "job.update", state: "na_fila" }),
      expect.objectContaining({ type: "offer", attempt: 2 }),
      expect.objectContaining({ type: "job.update", state: "oferecido" }),
    ])
  })

  test("a silent machine loses its safe offers; an unsafe one waits as incerto and its late acceptance counts", async () => {
    const it = harness()
    it.call([it.hello, it.submit("j-aaaaaaaa", [spec("android")]), it.submit("j-bbbbbbbb", [phone])])
    expect(it.offers().map((offer) => offer.job)).toEqual(["j-aaaaaaaa", "j-bbbbbbbb"])
    await it.later(46_000)
    expect([it.part("j-aaaaaaaa", "android")?.state, it.part("j-bbbbbbbb", "celular")]).toEqual([
      "na_fila",
      expect.objectContaining({ state: "incerto", held_state: "oferecido" }),
    ])
    // Back: the phone's acceptance (sent before the silence) arrives and counts; the withdrawn one is cancelled there.
    const back = it.call([accept("j-bbbbbbbb", "celular")])
    expect(back).toContainEqual(expect.objectContaining({ type: "attempt.cancel", job: "j-aaaaaaaa", attempt: 1 }))
    expect(it.part("j-bbbbbbbb", "celular")).toMatchObject({ state: "aceito", held_state: null })
  })

  test("a machine still reconciling after 5 minutes is as uncertain as a silent one for what it runs", async () => {
    const it = harness()
    it.call([it.hello, it.submit("j-aaaaaaaa", [spec("android")])])
    const running = [{ job: "j-aaaaaaaa", part: "android", attempt: 1 }]
    it.call([accept("j-aaaaaaaa", "android")], running)
    // It restarted and calls every 30 s while it reads its executions again (never silent).
    for (const _ of Array.from({ length: 9 })) {
      it.call([], running, { state: "reconciling" })
      await it.later(30_000)
    }
    expect(it.part("j-aaaaaaaa", "android")?.state).toBe("aceito")
    it.call([], running, { state: "reconciling" })
    await it.later(30_000)
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "incerto", held_state: "aceito" })
    // Still reconciling, its list does not bring the part back (it would come and go every round).
    it.call([], running, { state: "reconciling" })
    await it.later(1_000)
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "incerto" })
    // Done reconciling, it lists the attempt: back to where it was.
    it.call([], running)
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "aceito", held_state: null })
  })

  test("a late call with an old pulse never makes a silent machine come back", async () => {
    const it = harness()
    it.call([it.hello])
    await it.later(46_000)
    const state = () => it.db.query("SELECT state FROM hub_machine WHERE machine_id = 'm-Mac'").get()
    expect(state()).toEqual({ state: "silenciosa" })
    it.call([], [], { pulse: 1 })
    expect(state()).toEqual({ state: "silenciosa" })
    it.call()
    expect(state()).toEqual({ state: "ok" })
  })

  test("an accepted attempt missing from two pulses in a row is lost; a safe part runs again, an unsafe one does not", async () => {
    const it = harness()
    it.call([it.hello, it.submit("j-aaaaaaaa", [spec("android")]), it.submit("j-bbbbbbbb", [phone])])
    const both = [
      { job: "j-aaaaaaaa", part: "android", attempt: 1 },
      { job: "j-bbbbbbbb", part: "celular", attempt: 1 },
    ]
    it.call([accept("j-aaaaaaaa", "android"), accept("j-bbbbbbbb", "celular")], both)
    it.call([], both)
    // The machine forgot them (another database): one pulse is not enough, two are.
    it.call([], [])
    expect(it.part("j-aaaaaaaa", "android")?.state).toBe("aceito")
    it.call([], [])
    // The safe one is offered again at once (attempt 2); the unsafe one is lost for good.
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "oferecido", attempt_n: 2 })
    expect(it.part("j-bbbbbbbb", "celular")).toMatchObject({ state: "perdido", attempt_n: 1 })
    expect(JSON.parse(it.part("j-bbbbbbbb", "celular")!.outcome!)).toMatchObject({
      reason: "a máquina não conhece mais esta tentativa",
    })
  })

  test("a part left with scenarios without result runs once more with only those, and the results join", () => {
    const it = harness()
    it.call([it.hello, it.submit("j-aaaaaaaa", [spec("android")])])
    it.call([accept("j-aaaaaaaa", "android")], [{ job: "j-aaaaaaaa", part: "android", attempt: 1 }])
    const replies = it.call([
      report("j-aaaaaaaa", "android", 1, "concluido", outcome("incompleto", ["c1", "c2", "c3"], ["c1"])),
    ])
    expect(replies).toContainEqual(expect.objectContaining({ type: "offer", attempt: 2, only: ["c2", "c3"] }))
    it.call([
      accept("j-aaaaaaaa", "android", 2),
      report("j-aaaaaaaa", "android", 2, "concluido", outcome("aprovado", ["c2", "c3"], ["c2", "c3"])),
    ])
    expect(it.part("j-aaaaaaaa", "android")?.state).toBe("concluido")
    expect(it.inbox.find((body) => body.type === "result")).toMatchObject({
      parts: [{ part: "android", state: "concluido", attempts: 2, outcome: { verdict: "aprovado", lost: [] } }],
    })
  })

  test("an infrastructure failure with every scenario answered does not run again: it closes with what it gave", () => {
    const it = harness()
    it.call([it.hello, it.submit("j-aaaaaaaa", [spec("android")])])
    it.call([accept("j-aaaaaaaa", "android")], [{ job: "j-aaaaaaaa", part: "android", attempt: 1 }])
    const replies = it.call([
      report("j-aaaaaaaa", "android", 1, "perdido", {
        ...outcome("infraestrutura", ["c1"], ["c1"]),
        reason: "infraestrutura (saída 75)",
      }),
    ])
    expect(replies.filter((body) => body.type === "offer")).toEqual([])
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "perdido", attempt_n: 1 })
    expect(JSON.parse(it.part("j-aaaaaaaa", "android")!.outcome!)).toMatchObject({
      reason: "infraestrutura (saída 75)",
      scenarios: [{ id: "c1", result: "passou" }],
    })
  })

  test("a cancelled request never comes back: its uncertain part closes at once and nothing runs again", async () => {
    const it = harness()
    it.call([it.hello])
    // A session of the hub's own asks; the Mac runs it.
    it.hub.submit({ id: "j-aaaaaaaa", sessionID: "ses_hub", rootSessionID: "ses_hub", code, parts: [spec("android")] })
    await it.later(1_000)
    it.call()
    const running = [{ job: "j-aaaaaaaa", part: "android", attempt: 1 }]
    it.call([accept("j-aaaaaaaa", "android")], running)
    await it.later(46_000)
    expect(it.part("j-aaaaaaaa", "android")?.state).toBe("incerto")
    // Cancelled while the Mac is silent: closed now, the cancel waits for the Mac.
    it.hub.cancel("j-aaaaaaaa")
    await it.later(1_000)
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "cancelado" })
    expect(it.hub.notices()).toMatchObject([{ job: "j-aaaaaaaa", parts: [{ part: "android", state: "cancelado" }] }])
    // Past the 15 min, nothing is offered again; back, the Mac hears the cancel.
    await it.later(16 * 60_000)
    expect(it.call([], running)).toContainEqual(
      expect.objectContaining({ type: "attempt.cancel", job: "j-aaaaaaaa", attempt: 1 }),
    )
    expect(it.offers().map((offer) => offer.attempt)).toEqual([1])
  })

  test("a late report of an older attempt stays in its history and stops it; the part goes on", async () => {
    const it = harness()
    it.call([it.hello, it.submit("j-aaaaaaaa", [spec("android")])])
    it.call()
    await it.later(1_000)
    await it.later(30_000)
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "oferecido", attempt_n: 2 })
    // Attempt 1 had started after all: its report changes nothing but its own history, and it is cancelled.
    it.call([report("j-aaaaaaaa", "android", 1, "rodando")])
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "oferecido", attempt_n: 2 })
    expect(
      it.db.query("SELECT n, state, cancelled FROM hub_attempt WHERE job_id = 'j-aaaaaaaa' ORDER BY n").all(),
    ).toEqual([
      { n: 1, state: "rodando", cancelled: 1 },
      { n: 2, state: "oferecido", cancelled: 0 },
    ])
  })

  test("an uncertain part is lost after 15 min: a safe one runs again elsewhere, an unsafe one closes", async () => {
    const it = harness()
    it.call([it.hello, it.submit("j-aaaaaaaa", [spec("android")]), it.submit("j-bbbbbbbb", [phone])])
    it.call(
      [accept("j-aaaaaaaa", "android"), accept("j-bbbbbbbb", "celular")],
      [
        { job: "j-aaaaaaaa", part: "android", attempt: 1 },
        { job: "j-bbbbbbbb", part: "celular", attempt: 1 },
      ],
    )
    await it.later(46_000)
    expect(it.part("j-aaaaaaaa", "android")?.state).toBe("incerto")
    await it.later(3 * 60_000)
    expect(it.db.query("SELECT state FROM hub_machine WHERE machine_id = 'm-Mac'").get()).toEqual({ state: "fora" })
    await it.later(12 * 60_000)
    expect(it.part("j-aaaaaaaa", "android")).toMatchObject({ state: "na_fila" })
    expect(it.part("j-bbbbbbbb", "celular")).toMatchObject({ state: "perdido" })
    expect(JSON.parse(it.part("j-bbbbbbbb", "celular")!.outcome!)).toMatchObject({
      reason: "a máquina Mac não respondeu",
    })
  })

  test("a request replaces its session's waiting parts of the same test; one replaced entirely closes without notice", () => {
    const it = harness()
    const ios = spec("ios", { platform: "ios", needs: ["ios"] })
    const superseded = (replies: BancadaProtocol.FromHub[]) =>
      replies.flatMap((body) => (body.type === "submit.ack" ? body.superseded : []))
    // No machine offers Android nor iOS: everything waits.
    it.call([
      { ...it.hello, capabilities: {} },
      it.submit("j-aaaaaaaa", [spec("android")]),
      it.submit("j-cccccccc", [spec("android")], "ses_b"),
    ])
    expect(superseded(it.call([it.submit("j-dddddddd", [spec("android")])]))).toEqual(["j-aaaaaaaa"])
    expect(superseded(it.call([it.submit("j-bbbbbbbb", [spec("android"), ios])]))).toEqual(["j-dddddddd"])
    // Only B's iOS part is replaced: B goes on with its Android part.
    expect(superseded(it.call([it.submit("j-eeeeeeee", [ios])]))).toEqual([])
    expect(it.db.query("SELECT id, state FROM hub_job ORDER BY id").all()).toEqual([
      { id: "j-aaaaaaaa", state: "entregue" },
      { id: "j-bbbbbbbb", state: "aberto" },
      { id: "j-cccccccc", state: "aberto" },
      { id: "j-dddddddd", state: "entregue" },
      { id: "j-eeeeeeee", state: "aberto" },
    ])
    expect([it.part("j-bbbbbbbb", "android")?.state, it.part("j-bbbbbbbb", "ios")?.state]).toEqual([
      "na_fila",
      "cancelado",
    ])
    expect(JSON.parse(it.part("j-bbbbbbbb", "ios")!.outcome!)).toMatchObject({ reason: "substituída por j-eeeeeeee" })
    expect(it.part("j-cccccccc", "android")).toMatchObject({ state: "na_fila" })
  })

  test("an exclusive lock: the second request waits for it, and takes it when the first part ends", () => {
    const it = harness()
    const locked = spec("android", { exclusive: ["abacato:servidor-dev"], unsafe: true })
    it.call([it.hello, it.submit("j-aaaaaaaa", [locked]), it.submit("j-bbbbbbbb", [locked], "ses_b")])
    expect(it.offers().map((offer) => offer.job)).toEqual(["j-aaaaaaaa"])
    expect(it.inbox).toContainEqual(
      expect.objectContaining({
        type: "job.update",
        job: "j-bbbbbbbb",
        reason: expect.objectContaining({ code: "trava" }),
      }),
    )
    it.call([
      accept("j-aaaaaaaa", "android"),
      report("j-aaaaaaaa", "android", 1, "concluido", outcome("aprovado", ["c1"], ["c1"])),
    ])
    expect(it.offers().map((offer) => offer.job)).toEqual(["j-aaaaaaaa", "j-bbbbbbbb"])
  })

  test("a cancelled request stops what runs where it runs; a delivered one leaves a tombstone its id never runs past", async () => {
    const it = harness()
    it.call([it.hello, it.submit("j-aaaaaaaa", [spec("android"), spec("outra")])])
    const running = [{ job: "j-aaaaaaaa", part: "android", attempt: 1 }]
    it.call([accept("j-aaaaaaaa", "android")], running)
    const replies = it.call([{ type: "cancel", job: "j-aaaaaaaa" }], running)
    expect(
      replies.filter((body) => body.type === "attempt.cancel").map((body) => (body as { part: string }).part),
    ).toEqual(["android", "outra"])
    expect([it.part("j-aaaaaaaa", "android")?.state, it.part("j-aaaaaaaa", "outra")?.state]).toEqual([
      "aceito",
      "cancelado",
    ])
    it.call([report("j-aaaaaaaa", "android", 1, "cancelado", outcome("cancelado", [], []))])
    expect(it.inbox.find((body) => body.type === "result")).toMatchObject({ job: "j-aaaaaaaa" })
    it.call([{ type: "delivered", job: "j-aaaaaaaa" }])
    expect(it.db.query("SELECT COUNT(*) AS n FROM hub_part").get()).toEqual({ n: 0 })
    // Sent again (the origin's database restored, say): nothing runs.
    it.call([it.submit("j-aaaaaaaa", [spec("android")])])
    await it.later(1_000)
    it.call()
    expect(it.db.query("SELECT id, state FROM hub_job").all()).toEqual([{ id: "j-aaaaaaaa", state: "entregue" }])
    expect(it.db.query("SELECT COUNT(*) AS n FROM hub_part").get()).toEqual({ n: 0 })
  })
})
