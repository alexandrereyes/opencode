import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import { CoreError, createCore, type Machine } from "../src/bancada/daemon/core"
import type { Launcher } from "../src/bancada/daemon/executor"
import { makeMessages, type Stream } from "../src/bancada/daemon/messages"
import { migrate, NewerSchemaError, steps } from "../src/bancada/daemon/schema"
import { BancadaProtocol } from "../src/bancada/protocol"

const idle: Launcher = { start: async () => {}, status: async () => ({ state: "rodando" }) }
const machine = (name: string, hub: boolean, android = 0): Machine => ({
  machineID: `m-${name}`,
  instanceID: `i-${name}`,
  name,
  platform: hub ? "linux" : "darwin",
  hub,
  speed: "normal",
  capabilities: android ? { android: {} } : {},
  capacity: { memMb: 0, cpuMilli: 0, builds: 1, android, ios: 0 },
})
const core = (config: Machine, launcher: Launcher = idle, db = new Database(":memory:")) => {
  let n = 0
  return { db, core: createCore({ db, now: () => 1_000, random: () => `id-${++n}`, machine: config, launcher }) }
}
/** What the hub would send: one offer of one device per part, in one batch. */
const offers = (...parts: string[]): BancadaProtocol.SyncOutput => ({
  protocol: BancadaProtocol.version,
  ack: null,
  out: {
    stream: "hub-stream",
    base: 0,
    messages: parts.map((part, index) => ({
      seq: index + 1,
      body: {
        type: "offer",
        job: "j-7qk2m9xa",
        part,
        attempt: 1,
        spec: { ...spec, part, devices: { min: 1, max: 1 } },
        origin: { instanceID: "i", machineID: "m", name: "Linux", sessionID: "s", rootSessionID: "s" },
        code,
        devices: { min: 1, proposed: 1 },
      },
    })),
  },
})
const sent = (target: ReturnType<typeof core>) => target.core.outgoing().out.messages.map((message) => message.body)
const spec: BancadaProtocol.PartSpec = {
  part: "android",
  label: "Android",
  platform: "android",
  needs: ["android"],
  device: {},
  devices: { min: 2, max: 2 },
  exclusive: [],
  unsafe: false,
  args: [],
}
const code = { project: "exemplo", commit: "3417b7e3", remotes: [], inRemote: false }
/** Every row of every table: what a repeated message must leave as it was. */
const dump = (db: Database) =>
  db
    .query<{ name: string }, []>("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    .all()
    .map((table) => [table.name, db.query(`SELECT * FROM ${table.name}`).all()])

describe("message streams", () => {
  const pair = () => {
    let n = 0
    const sender = new Database(":memory:")
    const receiver = new Database(":memory:")
    migrate(sender)
    migrate(receiver)
    return {
      sender: makeMessages(
        sender,
        () => `stream-${++n}`,
        () => 0,
      ),
      receiver: makeMessages(
        receiver,
        () => `stream-${++n}`,
        () => 0,
      ),
      senderDb: sender,
      receiverDb: receiver,
    }
  }
  const take = (messages: ReturnType<typeof makeMessages>, stream: Stream) => {
    const applied: unknown[] = []
    messages.receive("sender", stream, (body) => applied.push(body))
    return applied
  }

  test("a stream delivered twice, late or with a hole applies each message once and in order", () => {
    const { sender, receiver } = pair()
    ;["a", "b", "c", "d"].forEach((body) => sender.send("receiver", body))
    const all = sender.outgoing("receiver")
    expect(take(receiver, { ...all, messages: all.messages.slice(0, 2) })).toEqual(["a", "b"])
    expect(take(receiver, all)).toEqual(["c", "d"])
    expect(take(receiver, all)).toEqual([])
    // A gap stops: the next message only, never one after a missing one.
    sender.send("receiver", "e")
    sender.send("receiver", "f")
    const later = sender.outgoing("receiver")
    expect(take(receiver, { ...later, messages: later.messages.filter((message) => message.body === "f") })).toEqual([])
    expect(take(receiver, later)).toEqual(["e", "f"])
  })

  test("an acknowledgement removes what it covers, and one of another stream removes nothing", () => {
    const { sender, receiver } = pair()
    ;["a", "b", "c"].forEach((body) => sender.send("receiver", body))
    take(receiver, { ...sender.outgoing("receiver"), messages: sender.outgoing("receiver").messages.slice(0, 2) })
    sender.acked("receiver", { stream: "another", seq: 3 })
    expect(sender.outgoing("receiver").messages).toHaveLength(3)
    sender.acked("receiver", receiver.ack("sender"))
    expect(sender.outgoing("receiver")).toMatchObject({ base: 2, messages: [{ seq: 3, body: "c" }] })
  })

  test("a receiver whose database was replaced starts after what its predecessor acknowledged", () => {
    const { sender, receiver } = pair()
    ;["a", "b"].forEach((body) => sender.send("receiver", body))
    take(receiver, sender.outgoing("receiver"))
    sender.acked("receiver", receiver.ack("sender"))
    sender.send("receiver", "c")
    const fresh = new Database(":memory:")
    migrate(fresh)
    const replaced = makeMessages(
      fresh,
      () => "stream-new",
      () => 0,
    )
    expect(take(replaced, sender.outgoing("receiver"))).toEqual(["c"])
  })
})

describe("core", () => {
  test("the hub and a machine applying the same exchange twice change nothing the second time", async () => {
    const hub = core(machine("Linux", true))
    const mac = core(machine("Mac", false, 2))
    mac.core.submit({ id: "j-7qk2m9xa", sessionID: "ses_a", rootSessionID: "ses_a", code, parts: [spec] })
    const input = JSON.parse(JSON.stringify(mac.core.outgoing()))
    const output = hub.core.sync(input)
    const afterFirst = dump(hub.db)
    expect(output.out.messages.map((message) => message.body.type)).toEqual(["submit.ack", "offer", "job.update"])
    hub.core.sync(input)
    expect(dump(hub.db)).toEqual(afterFirst)

    mac.core.incoming(output)
    const machineAfter = dump(mac.db)
    mac.core.incoming(output)
    expect(dump(mac.db)).toEqual(machineAfter)
  })

  test("an executor refuses an offer beyond its own free devices, whatever the hub believed", () => {
    const mac = core(machine("Mac", false, 1))
    mac.core.incoming({
      protocol: BancadaProtocol.version,
      ack: null,
      out: {
        stream: "hub-stream",
        base: 0,
        messages: [
          {
            seq: 1,
            body: {
              type: "offer",
              job: "j-7qk2m9xa",
              part: "android",
              attempt: 1,
              spec,
              origin: { instanceID: "i", machineID: "m", name: "Linux", sessionID: "s", rootSessionID: "s" },
              code,
              devices: { min: 2, proposed: 2 },
            },
          },
        ],
      },
    })
    expect(mac.core.outgoing().out.messages.map((message) => message.body)).toContainEqual({
      type: "offer.reply",
      job: "j-7qk2m9xa",
      part: "android",
      attempt: 1,
      accepted: false,
      reason: { code: "orcamento", text: "aguardando folga" },
    })
    expect(mac.db.query("SELECT COUNT(*) AS n FROM lease").get()).toEqual({ n: 0 })
  })

  test("two ticks at once report the end of an execution once", async () => {
    const gate = Promise.withResolvers<void>()
    const mac = core(machine("Mac", false, 1), {
      start: async () => {},
      status: async () => {
        await gate.promise
        return { state: "done", exit: 0, planned: ["a1"], scenarios: [{ id: "a1", result: "passou" }] }
      },
    })
    mac.core.incoming(offers("android"))
    const both = Promise.all([mac.core.tick(), mac.core.tick()])
    gate.resolve()
    await both
    expect(sent(mac).filter((body) => body.type === "attempt" && body.state === "concluido")).toHaveLength(1)
  })

  test("a start that fails, or a status that cannot be read, never holds the other attempts", async () => {
    const started: string[] = []
    const mac = core(machine("Mac", false, 3), {
      start: async (launch) => {
        if (launch.part === "falha") throw new Error("sem processo")
        started.push(launch.part)
      },
      status: async (key) => {
        if (key.part === "muda") throw new Error("ps estourou o prazo")
        return { state: "rodando" }
      },
    })
    mac.core.incoming(offers("falha", "muda", "segue"))
    await mac.core.tick()
    expect(started).toEqual(["muda", "segue"])
    const reports = sent(mac).filter((body) => body.type === "attempt")
    expect(reports).toEqual([
      expect.objectContaining({
        part: "falha",
        state: "perdido",
        outcome: expect.objectContaining({ reason: "a partida falhou: sem processo" }),
      }),
      expect.objectContaining({ part: "segue", state: "rodando" }),
    ])
  })

  test("sync is the hub's alone and refuses another protocol by name", () => {
    const hub = core(machine("Linux", true))
    const mac = core(machine("Mac", false))
    const input = mac.core.outgoing()
    const refusal = (run: () => unknown) => {
      try {
        run()
      } catch (error) {
        return error instanceof CoreError ? { type: error.type, data: error.data } : error
      }
    }
    expect(refusal(() => mac.core.sync(input))).toEqual({ type: "not_hub", data: undefined })
    expect(refusal(() => hub.core.sync({ ...input, protocol: 0 }))).toEqual({
      type: "protocol_mismatch",
      data: { expected: BancadaProtocol.version },
    })
    expect(
      refusal(() => hub.core.sync({ ...input, out: { ...input.out, messages: [{ seq: 1, body: { type: "x" } }] } })),
    ).toMatchObject({ type: "invalid" })
  })
})

describe("schema", () => {
  test("a database of a newer release is refused, and migrating twice changes nothing", () => {
    const db = new Database(":memory:")
    migrate(db)
    migrate(db)
    expect(db.query("SELECT value FROM meta WHERE key = 'schema_version'").get()).toEqual({
      value: String(steps.length),
    })
    db.run("UPDATE meta SET value = ? WHERE key = 'schema_version'", [String(steps.length + 1)])
    expect(() => migrate(db)).toThrow(NewerSchemaError)
  })
})
