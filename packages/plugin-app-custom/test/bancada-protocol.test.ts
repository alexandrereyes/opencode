import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import { Schema } from "effect"
import { CoreError, createCore, type Machine } from "../src/bancada/daemon/core"
import type { Launcher } from "../src/bancada/daemon/executor"
import { makeMessages, type Stream } from "../src/bancada/daemon/messages"
import { migrate, NewerSchemaError, steps } from "../src/bancada/daemon/schema"
import { BancadaProtocol } from "../src/bancada/protocol"

const idle: Launcher = {
  start: async () => {},
  status: async () => ({ state: "rodando" }),
  cancel: async () => {},
  reap: async () => {},
  held: () => false,
  cleanup: async () => {},
}
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
  return {
    db,
    core: createCore({ db, now: () => 1_000, random: () => `id-${++n}`, machine: config, launcher, log: () => {} }),
  }
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
const code = { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false }
/** Every row of every table: what a repeated message must leave as it was. */
const dump = (db: Database) =>
  db
    .query<{ name: string }, []>("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    .all()
    .map((table) => [table.name, db.query(`SELECT * FROM ${table.name}`).all()])

describe("message streams", () => {
  const pair = () => {
    let n = 0
    const logs: string[] = []
    const open = () => {
      const db = new Database(":memory:")
      migrate(db)
      return db
    }
    const sender = open()
    const receiver = open()
    const messages = (db: Database) =>
      makeMessages(
        db,
        () => `stream-${++n}`,
        () => 0,
        (line) => logs.push(line),
      )
    return {
      sender: messages(sender),
      receiver: messages(receiver),
      senderDb: sender,
      receiverDb: receiver,
      messages,
      logs,
    }
  }
  const take = (messages: ReturnType<typeof makeMessages>, stream: Stream, fail?: string) => {
    const applied: unknown[] = []
    messages.receive("sender", stream, (body) => {
      if (body === fail) throw new Error(`cannot apply ${body}`)
      applied.push(body)
    })
    return applied
  }
  /** The same database as it was at this moment: a backup to restore later. */
  const copy = (db: Database) => Database.deserialize(db.serialize())

  test("a stream delivered twice, late or with a hole applies each message once and in order (rule 1)", () => {
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

  test("an acknowledgement removes what it covers, and one of another stream removes nothing (rule 5)", () => {
    const { sender, receiver } = pair()
    ;["a", "b", "c"].forEach((body) => sender.send("receiver", body))
    take(receiver, { ...sender.outgoing("receiver"), messages: sender.outgoing("receiver").messages.slice(0, 2) })
    sender.acked("receiver", { stream: "another", seq: 3 })
    expect(sender.outgoing("receiver").messages).toHaveLength(3)
    sender.acked("receiver", receiver.ack("sender"))
    expect(sender.outgoing("receiver")).toMatchObject({ base: 2, messages: [{ seq: 3, body: "c" }] })
  })

  test("a receiver whose database was replaced starts after what its predecessor acknowledged (rule 2)", () => {
    const { sender, receiver, messages } = pair()
    ;["a", "b"].forEach((body) => sender.send("receiver", body))
    take(receiver, sender.outgoing("receiver"))
    sender.acked("receiver", receiver.ack("sender"))
    sender.send("receiver", "c")
    const fresh = new Database(":memory:")
    migrate(fresh)
    expect(take(messages(fresh), sender.outgoing("receiver"))).toEqual(["c"])
  })

  test("a receiver restored from an older copy goes on from what was acknowledged instead of waiting forever (rule 3)", () => {
    const { sender, receiver, receiverDb, messages, logs } = pair()
    ;["a", "b"].forEach((body) => sender.send("receiver", body))
    take(receiver, sender.outgoing("receiver"))
    const backup = copy(receiverDb)
    ;["c", "d"].forEach((body) => sender.send("receiver", body))
    take(receiver, sender.outgoing("receiver"))
    sender.acked("receiver", receiver.ack("sender"))
    sender.send("receiver", "e")
    // The restored receiver's cursor is at 2; "c" and "d" were acknowledged by the database it replaced.
    expect(take(messages(backup), sender.outgoing("receiver"))).toEqual(["e"])
    expect(logs.join("\n")).toContain("going on from 4")
  })

  test("a sender restored from an older copy starts a new stream, so what it writes next is not skipped (rule 4)", () => {
    const { sender, receiver, senderDb, messages } = pair()
    sender.send("receiver", "a")
    const backup = copy(senderDb)
    ;["b", "c"].forEach((body) => sender.send("receiver", body))
    take(receiver, sender.outgoing("receiver"))
    const restored = messages(backup)
    restored.send("receiver", "x")
    // The receiver acknowledges 3; the restored sender only wrote up to 2, the same number "x" now has.
    restored.acked("receiver", receiver.ack("sender"))
    const stream = restored.outgoing("receiver")
    expect(stream.stream).not.toBe(receiver.ack("sender")?.stream)
    expect(take(receiver, stream)).toEqual(["a", "x"])
  })

  test("a message its handler cannot apply goes to dead_letter and the stream goes on (rule 6)", () => {
    const { sender, receiver, receiverDb, logs } = pair()
    ;["a", "poison", "c"].forEach((body) => sender.send("receiver", body))
    expect(take(receiver, sender.outgoing("receiver"), "poison")).toEqual(["a", "c"])
    expect(receiverDb.query("SELECT seq, body, error FROM dead_letter").all()).toEqual([
      { seq: 2, body: '"poison"', error: "cannot apply poison" },
    ])
    expect(receiver.ack("sender")).toMatchObject({ seq: 3 })
    expect(logs.join("\n")).toContain("dead_letter")
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
      ...idle,
      status: async () => {
        await gate.promise
        return {
          state: "done",
          ending: {
            stage: "run",
            exit: 0,
            planned: { versao: 1, cenarios: [{ id: "a1" }] },
            summary: { versao: 1, cenarios: [{ id: "a1", resultado: "passou" }] },
          },
        }
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
      ...idle,
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

  test("back after a restart, an executor takes no offer until one round has read everything it started", async () => {
    const readable = { value: true }
    const launcher: Launcher = {
      ...idle,
      status: async () => {
        if (!readable.value) throw new Error("ps estourou o prazo")
        return { state: "rodando" }
      },
    }
    const first = core(machine("Mac", false, 2), launcher)
    first.core.incoming(offers("android"))
    await first.core.tick()
    // The process dies; another opens the same database while `ps` cannot answer.
    readable.value = false
    const again = core(machine("Mac", false, 2), launcher, first.db)
    await again.core.tick()
    const later = offers("outra")
    again.core.incoming({
      ...later,
      out: { ...later.out, messages: later.out.messages.map((message) => ({ ...message, seq: 2 })) },
    })
    expect(again.core.reconciling()).toBe(true)
    expect(again.core.outgoing()).toMatchObject({
      pulse: { state: "reconciling" },
      out: {
        messages: expect.arrayContaining([
          expect.objectContaining({
            body: expect.objectContaining({
              type: "offer.reply",
              part: "outra",
              accepted: false,
              reason: expect.objectContaining({ code: "reconciliando" }),
            }),
          }),
        ]),
      },
    })
    readable.value = true
    await again.core.tick()
    expect(again.core.reconciling()).toBe(false)
  })

  test("an ended attempt's reservation goes back only once the machine gave back what it held", async () => {
    const holds = { value: true }
    const mac = core(machine("Mac", false, 1), {
      ...idle,
      status: async () => ({
        state: "done",
        ending: {
          stage: "run",
          exit: 0,
          planned: { versao: 1, cenarios: [{ id: "a1" }] },
          summary: { versao: 1, cenarios: [{ id: "a1", resultado: "passou" }] },
        },
      }),
      held: () => holds.value,
    })
    mac.core.incoming(offers("android"))
    await mac.core.tick()
    // The hub hears of the end at once; the device it reserved still counts, an orphan may still use it.
    expect(sent(mac)).toContainEqual(expect.objectContaining({ type: "attempt", part: "android", state: "concluido" }))
    expect(mac.core.outgoing().pulse.free.android).toBe(0)
    holds.value = false
    await mac.core.tick()
    expect(mac.core.outgoing().pulse.free.android).toBe(1)
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

describe("message schemas", () => {
  test("a commit is a full SHA and a remote has a remote's shape: nothing in a message can be a command option", () => {
    const valid = (schema: Schema.Schema<string>, values: string[]) => values.map((value) => Schema.is(schema)(value))
    expect(
      valid(BancadaProtocol.Commit, ["3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", "a".repeat(64), "3417b7e3", "--all"]),
    ).toEqual([true, true, false, false])
    expect(
      valid(BancadaProtocol.RemoteURL, [
        "https://github.com/alexandrereyes/opencode",
        "git@github.com:alexandrereyes/AbacatoV3.git",
        "ssh://git@host:2222/grupo/projeto",
        "/workspace/Dev/AbacatoV3",
        "-oProxyCommand=touch@x:y",
        "--upload-pack=x",
      ]),
    ).toEqual([true, true, true, false, false, false])
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
