// Simulation of several Bancada cores in one process (plan, section 15.2): each with an in-memory database, a virtual
// clock, a scripted launcher and a network that drops, delays, duplicates and partitions. Every step checks the
// invariants; `settle` checks the ones that hold only at the end.
import { Database } from "bun:sqlite"
import type { Reading } from "../../src/bancada/daemon/brake"
import { CoreError, createCore, type Core, type Machine, type timings } from "../../src/bancada/daemon/core"
import type { Blobs } from "../../src/bancada/daemon/blobs"
import {
  CodeMissing,
  type AttemptKey,
  type Launch,
  type Launcher,
  type Placed,
  type Status,
} from "../../src/bancada/daemon/executor"
import type { BlobLink, Files } from "../../src/bancada/daemon/transfers"
import type { NewJob } from "../../src/bancada/daemon/origin"
import type { BancadaProtocol } from "../../src/bancada/protocol"

/** How a part's execution goes, on virtual time. */
export type Script =
  | {
      /** How long the start takes (the code coming from far): the round must never wait for it. */
      readonly startMs?: number
      readonly buildMs: number
      readonly runMs: number
      readonly exit: number
      readonly planned: ReadonlyArray<string>
      readonly scenarios: ReadonlyArray<BancadaProtocol.Scenario>
      /** Devices the Bancada saw fall during the run (their failures are lost, not failed). */
      readonly fell?: ReadonlyArray<string>
      /**
       * How many devices its plan can use, said once its build ended: the part asks for the ones it lacks (`grow`) or
       * gives back the rest (`shrink`), as the device pool does.
       */
      readonly useful?: number
    }
  | { readonly vanishMs: number }

/** Faults of one direction of the network. */
export type Faults = {
  readonly drop?: number
  readonly duplicate?: number
  readonly delayMs?: readonly [number, number]
}

export type SimMachine = {
  readonly name: string
  /** Replaced by `restart`: a new core on the same database, as a restarted process. */
  core: Core
  /** Replaced by `replaceDb`: another database (a wiped folder, or a copy restored from before). */
  db: Database
  readonly config: Machine
  awake: boolean
}

export function createWorld(options: {
  readonly seed: number
  readonly toHub?: Faults
  readonly toMachine?: Faults
  /** Virtual-time windows during which everything between a machine and the hub is lost. */
  readonly partitions?: ReadonlyArray<{ readonly machine: string; readonly from: number; readonly to: number }>
  readonly timings?: Partial<typeof timings>
  /** A machine whose calls say another protocol version (an older or newer release). */
  readonly versions?: Readonly<Record<string, number>>
  /**
   * The code of a request is only at its origin: a machine that runs another's request has it only through the hub,
   * as a bundle of `bundleBytes` (no remote, no copy of its own).
   */
  readonly codeTravels?: { readonly bundleBytes: number }
}) {
  const clock = { now: 1_000_000 }
  const random = rng(options.seed)
  const machines = new Map<string, SimMachine>()
  const scripts = new Map<string, Script>()
  /** Executions go on whatever happens to the Bancada process; they count only the time their machine is awake. */
  const runs = new Map<
    string,
    {
      awakeMs: number
      /** How long its machine slept while it ran. */
      sleptMs: number
      readonly script: Script
      cancelled: boolean
      readonly only?: ReadonlyArray<string>
      readonly unsafe: boolean
      /** Devices granted at its start; whether it reported running once, and asked for its plan's devices. */
      readonly devices: number
      ran: boolean
      planned: boolean
    }
  >()
  const facts = {
    starts: new Map<string, number>(),
    notices: new Map<string, number>(),
    results: new Map<string, Set<number>>(),
    submitted: new Map<string, { readonly machine: string; readonly job: NewJob }>(),
    delivered: new Map<string, ReadonlyArray<BancadaProtocol.PartResult>>(),
    /** Offers an executor refused, by machine and sequence number: the hub offered more than the machine had. */
    refusals: new Set<string>(),
    states: new Map<string, string[]>(),
    /** The most devices each machine had reserved at once. */
    peak: new Map<string, number>(),
    /** Every group started: on which machine, with which parts. */
    launches: [] as { machine: string; job: string; group: string; parts: string[] }[],
    /** Every start that fetched its code from a bundle that came through the hub. */
    bundles: [] as { machine: string; job: string }[],
    /** The text of each notice delivered. */
    texts: new Map<string, string>(),
    /** Every chunk a machine sent to the hub, by its offset. */
    puts: [] as { machine: string; transfer: string; offset: number }[],
    /** What each part's plan asked for after its build, and the devices it had then. */
    grown: [] as { machine: string; attempt: string; wanted: number; devices: number }[],
  }
  /** Starts still bringing their code, released when the virtual clock reaches them. */
  const starting: { readonly at: number; readonly resolve: () => void }[] = []
  const logs: string[] = []
  const inflight: { readonly at: number; readonly order: number; readonly run: () => void }[] = []
  let order = 0
  let hub: SimMachine | undefined

  const id = () =>
    Array.from({ length: 4 }, () =>
      Math.floor(random() * 2 ** 32)
        .toString(16)
        .padStart(8, "0"),
    ).join("")
  const key = (value: AttemptKey) => `${value.job}/${value.part}/${value.attempt}`
  const scriptOf = (job: string, part: string, attempt: number) =>
    scripts.get(`${job}/${part}#${attempt}`) ?? scripts.get(`${job}/${part}`)

  /** Every machine's transfer files, by `<machine>/<name>`: bundles made, bundles received. */
  const disk = new Map<string, Uint8Array>()
  /** What a request's bundle holds: the same bytes wherever it is made. */
  const bundleOf = (job: string) =>
    new Uint8Array(options.codeTravels?.bundleBytes ?? 0).map(
      (_, index) => (job.charCodeAt(index % job.length) + index) % 251,
    )
  /**
   * Faults of transfers: the hub's store spoils the next `spoil` files it receives, after its own check (`sha256`
   * wrong on the way out); the `cut`-th chunk sent to the hub from now on is lost on the way.
   */
  const store = { spoil: 0, cut: 0, unbundled: false, unapplied: 0 }
  const files = (machine: string): Files => ({
    path: (name) => `${machine}/${name}`,
    size: async (file) => disk.get(file)?.byteLength ?? 0,
    sha256: async (file) => sha256(disk.get(file) ?? new Uint8Array(0)),
    read: async (file, offset, length) => (disk.get(file) ?? new Uint8Array(0)).slice(offset, offset + length),
    append: async (file, data) => void disk.set(file, concat(disk.get(file) ?? new Uint8Array(0), data)),
    remove: async (file) => void disk.delete(file),
    bundle: async ({ job, file }) => {
      if (!machines.get(machine)?.awake) throw new Error(`${machine} is asleep`)
      if (store.unbundled) return false
      disk.set(file, bundleOf(job))
      return true
    },
    have: async () => [],
    deliver: (job, part, name) => `${machine}/entrega/${job}/${part}/${name}`,
    copy: async (from, to) => void disk.set(to, disk.get(from) ?? new Uint8Array(0)),
    release: async () => {},
  })
  /** The hub's `blob.put` and `blob.get` through the network: nothing gets through a cut. */
  const blobLink = (machine: string): BlobLink => {
    const reach = () => {
      if (!hub?.awake || faults(undefined, machine).length === 0) throw new Error("the hub did not answer")
      return hub.core
    }
    return {
      put: async (input) => {
        facts.puts.push({ machine, transfer: input.transfer, offset: input.offset })
        if (store.cut > 0 && --store.cut === 0) throw new Error("the connection dropped")
        return wire(await reach().blobPut(wire(input)))
      },
      get: async (input) => wire(await reach().blobGet(wire(input))),
    }
  }
  /** The hub's store of transfers, in memory, with the checks of `blobs.ts`. */
  const transfers = new Map<string, { expiresAt: number; files: Map<number, { data: Uint8Array; done: boolean }> }>()
  const blobs: Blobs = {
    open: async (transfer) =>
      void (
        transfers.has(transfer.id) || transfers.set(transfer.id, { expiresAt: transfer.expiresAt, files: new Map() })
      ),
    put: async (request) => {
      const known = transfers.get(request.transfer)
      if (!known) return { ok: false, reason: "unknown" }
      if (clock.now > known.expiresAt) return { ok: false, reason: "expired" }
      const entry = known.files.get(request.file.index) ?? { data: new Uint8Array(0), done: false }
      if (entry.done) return { ok: true, received: entry.data.byteLength, done: true }
      if (request.offset !== entry.data.byteLength)
        return { ok: false, reason: "offset", received: entry.data.byteLength }
      const data = concat(entry.data, request.data)
      if (data.byteLength > request.file.size) return { ok: false, reason: "size", received: entry.data.byteLength }
      if (!request.end) {
        known.files.set(request.file.index, { data, done: false })
        return { ok: true, received: data.byteLength, done: false }
      }
      if (data.byteLength !== request.file.size) return { ok: false, reason: "size", received: data.byteLength }
      if (sha256(data) !== request.file.sha256) {
        known.files.delete(request.file.index)
        return { ok: false, reason: "sha256", received: 0 }
      }
      const spoiled = store.spoil > 0 && data.byteLength > 0
      if (spoiled) store.spoil--
      known.files.set(request.file.index, {
        data: spoiled ? data.map((byte, index) => (index === 0 ? byte ^ 1 : byte)) : data,
        done: true,
      })
      return { ok: true, received: data.byteLength, done: true }
    },
    get: async (request) => {
      const known = transfers.get(request.transfer)
      if (!known) return { ok: false, reason: "unknown" }
      if (clock.now > known.expiresAt) return { ok: false, reason: "expired" }
      const entry = known.files.get(request.index)
      if (!entry?.done) return { ok: false, reason: "incomplete" }
      const data = entry.data.slice(request.offset, request.offset + Math.min(request.size, 1024 * 1024))
      return { ok: true, data, end: request.offset + data.byteLength >= entry.data.byteLength }
    },
    file: async () => undefined,
    remove: async (transfer) => void transfers.delete(transfer),
    expire: async () => 0,
  }

  const launcher = (machine: string): Launcher => ({
    start: async (launch: Launch) => {
      const from = facts.submitted.get(launch.job)?.machine
      if (options.codeTravels && from && from !== machine) {
        if (!launch.bundle) throw new CodeMissing(`${machine} has no copy of ${launch.job}`)
        const got = disk.get(launch.bundle)
        if (!got || sha256(got) !== sha256(bundleOf(launch.job))) throw new Error("git bundle verify failed")
        // A bundle whose prerequisites this folder lacks: the start reports it, as the process launcher does.
        if (store.unapplied > 0) {
          store.unapplied--
          throw new CodeMissing("bundle: git saiu com 1", true)
        }
        facts.bundles.push({ machine, job: launch.job })
      }
      facts.launches.push({
        machine,
        job: launch.job,
        group: launch.group,
        parts: launch.parts.map((part) => part.part),
      })
      const found = launch.parts.map((part) => {
        const script = scriptOf(launch.job, part.part, part.attempt)
        if (!script) throw new Error(`no script for ${launch.job}/${part.part}`)
        return { part, script }
      })
      const slow = Math.max(0, ...found.map((item) => ("startMs" in item.script ? (item.script.startMs ?? 0) : 0)))
      if (slow) await new Promise<void>((resolve) => starting.push({ at: clock.now + slow, resolve }))
      for (const { part, script } of found) {
        const name = `${machine}:${launch.job}/${part.part}/${part.attempt}`
        if (runs.has(name)) continue
        runs.set(name, {
          awakeMs: 0,
          sleptMs: 0,
          script,
          cancelled: false,
          unsafe: part.spec.unsafe,
          ...(part.only ? { only: part.only } : {}),
          devices: part.devices,
          ran: false,
          planned: false,
        })
        const counted = `${launch.job}/${part.part}`
        facts.starts.set(counted, (facts.starts.get(counted) ?? 0) + 1)
      }
    },
    status: async (attempt: Placed): Promise<Status> => {
      const run = runs.get(`${machine}:${key(attempt)}`)
      if (!run) return { state: "gone", reason: "no execution" }
      const elapsed = run.awakeMs
      if (run.cancelled) return { state: "done", ending: { stage: "run", cause: "cancelado" } }
      if ("vanishMs" in run.script)
        return elapsed < run.script.vanishMs
          ? { state: "rodando" }
          : { state: "done", ending: { stage: "run", cause: "runner_morto" } }
      if (elapsed < run.script.buildMs) return { state: "compilando" }
      // Its plan speaks the round after its build ended (its share of the reservation went back then).
      const useful = run.script.useful
      if (useful !== undefined && run.ran && !run.planned) {
        run.planned = true
        const core = machines.get(machine)!.core
        const devices = useful < run.devices ? (core.shrink(attempt, useful), useful) : core.grow(attempt, useful)
        facts.grown.push({ machine, attempt: key(attempt), wanted: useful, devices })
      }
      run.ran = true
      if (elapsed < run.script.buildMs + run.script.runMs) return { state: "rodando" }
      const scenarios = run.script.scenarios
      // The project's two files, as a real run writes them; a failure's evidence in its output folder.
      const out = `${machine}/attempts/${key(attempt)}/out`
      const evidence = Object.fromEntries(
        run.script.scenarios
          .filter((item) => item.result === "falhou")
          .flatMap((item) => item.evidence ?? [])
          .map((relative) => {
            const data = new TextEncoder().encode(`evidência ${relative} de ${key(attempt)}`)
            disk.set(`${out}/${relative}`, data)
            return [relative, { file: `${out}/${relative}`, size: data.byteLength, sha256: sha256(data) }] as const
          }),
      )
      return {
        state: "done",
        ending: {
          stage: "run",
          exit: run.script.exit,
          files: { evidence },
          ...(run.script.fell ? { fell: run.script.fell } : {}),
          ...(run.sleptMs > 0 ? { sleptMs: run.sleptMs } : {}),
          ...(run.only ? { only: run.only } : {}),
          planned: {
            versao: 1,
            cenarios: run.script.planned.map((id) => {
              const name = scenarios.find((item) => item.id === id)?.name
              return { id, ...(name ? { nome: name } : {}) }
            }),
          },
          summary: {
            versao: 1,
            cenarios: run.script.scenarios.map((item) => ({
              id: item.id,
              resultado: item.result,
              ...(item.message ? { mensagem: item.message } : {}),
              ...(item.device ? { aparelho: item.device } : {}),
              ...(item.evidence ? { evidencias: item.evidence } : {}),
            })),
          },
        },
      }
    },
    cancel: async (attempt) => {
      const run = runs.get(`${machine}:${key(attempt)}`)
      if (run) run.cancelled = true
    },
    stop: async (attempt) => {
      const run = runs.get(`${machine}:${key(attempt)}`)
      if (run) run.cancelled = true
    },
    reap: async () => {},
    held: () => false,
    // The attempt's folder goes with it, evidence included (the origin has its copy by then).
    cleanup: async (attempt) =>
      [...disk.keys()]
        .filter((file) => file.startsWith(`${machine}/attempts/${key(attempt)}/`))
        .forEach((file) => disk.delete(file)),
  })

  /**
   * One round of a machine. Every port of the world answers at once (in microtasks): a round still running when the
   * next timer fires is waiting for something outside it, which a real round must never do.
   */
  const round = async (machine: SimMachine) => {
    const late = new Promise<"late">((resolve) => setTimeout(() => resolve("late"), 0))
    if ((await Promise.race([machine.core.tick().then(() => "done" as const), late])) === "late")
      throw new Error(`${machine.name}: a round waited for work outside it`)
  }

  const build = (config: Machine, db: Database) =>
    createCore({
      db,
      now: () => clock.now,
      random: id,
      machine: config,
      launcher: launcher(config.name),
      log: (line) => logs.push(`${config.name}: ${line}`),
      ...(options.timings ? { timings: options.timings } : {}),
      files: files(config.name),
      ...(config.hub ? { blobs } : { blobLink: blobLink(config.name) }),
    })

  const faults = (direction: Faults | undefined, machine: string) => {
    if (options.partitions?.some((cut) => cut.machine === machine && clock.now >= cut.from && clock.now < cut.to))
      return []
    if (random() < (direction?.drop ?? 0)) return []
    const delay = () => {
      const [min, max] = direction?.delayMs ?? [0, 0]
      return min + Math.floor(random() * (max - min + 1))
    }
    return random() < (direction?.duplicate ?? 0) ? [delay(), delay()] : [delay()]
  }
  const later = (delay: number, run: () => void) => inflight.push({ at: clock.now + delay, order: order++, run })
  const wire = <T>(value: T): T => JSON.parse(JSON.stringify(value))

  /** One call of a machine to the hub, through the faulty network. */
  const exchange = (machine: SimMachine) => {
    if (!hub) throw new Error("no hub")
    const input = { ...wire(machine.core.outgoing()), protocol: options.versions?.[machine.name] ?? 1 }
    for (const delay of faults(options.toHub, machine.name))
      later(delay, () => {
        if (!hub?.awake) return
        input.out.messages
          .filter((message) => message.body.type === "offer.reply" && !message.body.accepted)
          .forEach((message) => facts.refusals.add(`${machine.name}:${message.seq}`))
        // A refusal comes back as the link reads it from the hub's RPC error.
        const answer = attempt(() => wire(hub!.core.sync(input)))
        if (answer instanceof CoreError) {
          const refusal = { type: answer.type, message: answer.message }
          for (const back of faults(options.toMachine, machine.name))
            later(back, () => machine.awake && machine.core.refused(refusal))
          return
        }
        const output = answer
        for (const back of faults(options.toMachine, machine.name))
          later(back, () => {
            if (!machine.awake) return
            observe(output)
            machine.core.incoming(output)
          })
      })
  }

  /** Every `result` message the origin receives, by sequence number: a job closes once if there is only one. */
  const observe = (output: BancadaProtocol.SyncOutput) =>
    output.out.messages
      .filter((message) => message.body.type === "result")
      .forEach((message) => {
        const job = (message.body as typeof BancadaProtocol.Result.Type).job
        const seen = facts.results.get(job) ?? new Set<number>()
        seen.add(message.seq)
        facts.results.set(job, seen)
      })

  /** The plugin of each server: delivers every notice and acknowledges it. */
  const deliver = (machine: SimMachine) =>
    machine.core.notices().forEach((notice) => {
      facts.notices.set(notice.job, (facts.notices.get(notice.job) ?? 0) + 1)
      facts.delivered.set(notice.job, notice.parts)
      facts.texts.set(notice.job, notice.text)
      machine.core.delivered(notice.job)
    })

  /** The states every part of the hub's queue passes through, for scenarios that check the way, not only the end. */
  const record = () =>
    hub?.db
      .query<{ job_id: string; part: string; state: string }, []>("SELECT job_id, part, state FROM hub_part")
      .all()
      .forEach((row) => {
        const states = facts.states.get(`${row.job_id}/${row.part}`) ?? []
        if (states.at(-1) !== row.state) facts.states.set(`${row.job_id}/${row.part}`, [...states, row.state])
      })

  const invariants = () => {
    for (const machine of machines.values()) {
      const used = machine.db
        .query<
          BancadaProtocol.Vector,
          []
        >("SELECT COALESCE(SUM(mem_mb), 0) AS memMb, COALESCE(SUM(cpu_milli), 0) AS cpuMilli, COALESCE(SUM(builds), 0) AS builds, COALESCE(SUM(android), 0) AS android, COALESCE(SUM(ios), 0) AS ios FROM lease WHERE state = 'active'")
        .get()!
      const over = (Object.keys(used) as (keyof BancadaProtocol.Vector)[]).filter(
        (key) => used[key] > machine.config.capacity[key],
      )
      if (over.length)
        throw new Error(`${machine.name} reserved beyond its budget (${over.join(", ")}): ${JSON.stringify(used)}`)
      facts.peak.set(machine.name, Math.max(facts.peak.get(machine.name) ?? 0, used.android + used.ios))
    }
    for (const [job, count] of facts.notices) if (count > 1) throw new Error(`${job} was noticed ${count} times`)
    for (const [job, seqs] of facts.results) if (seqs.size > 1) throw new Error(`${job} closed ${seqs.size} times`)
    // An unsafe part (a phone, real accounts, a lock, secrets) never runs twice at once, anywhere; a safe one may run
    // on two machines when one stopped answering (the worst case is running twice, never overload), never twice on one.
    const live = new Map<string, number>()
    for (const [name, run] of runs) {
      const ended =
        run.cancelled ||
        ("vanishMs" in run.script
          ? run.awakeMs >= run.script.vanishMs
          : run.awakeMs >= run.script.buildMs + run.script.runMs)
      if (ended) continue
      const part = name.slice(name.indexOf(":") + 1, name.lastIndexOf("/"))
      const where = run.unsafe ? part : `${name.slice(0, name.indexOf(":"))}:${part}`
      live.set(where, (live.get(where) ?? 0) + 1)
    }
    for (const [part, count] of live) if (count > 1) throw new Error(`${part} runs ${count} times at once`)
  }

  return {
    clock,
    machines,
    facts,
    logs,
    /** The hub's store spoils the next `count` files it receives (after its own check). */
    spoil: (count: number) => {
      store.spoil = count
    },
    /** The next `count` bundles do not apply where they arrive (`git bundle verify` exits 1). */
    unapply: (count: number) => {
      store.unapplied = count
    },
    /** From now on no origin can make a bundle (git refuses). */
    unbundle: () => {
      store.unbundled = true
    },
    /**
     * Writes a message straight into a machine's outbox to the hub, as a release with another shape would: its body may
     * be anything.
     */
    inject: (name: string, body: unknown) => {
      const db = machines.get(name)!.db
      const peer = db.query<{ out_seq: number }, []>("SELECT out_seq FROM peer WHERE peer = 'hub'").get()!
      db.run("UPDATE peer SET out_seq = ? WHERE peer = 'hub'", [peer.out_seq + 1])
      db.run("INSERT INTO outbox (peer, seq, body, created_at) VALUES ('hub', ?, ?, ?)", [
        peer.out_seq + 1,
        JSON.stringify(body),
        clock.now,
      ])
    },
    /** The `nth` chunk sent to the hub from now on is lost on the way (the connection drops). */
    cut: (nth: number) => {
      store.cut = nth
    },
    disk,
    addMachine: (input: { readonly name: string; readonly hub?: boolean } & Partial<Omit<Machine, "hub" | "name">>) => {
      const config: Machine = {
        machineID: `m-${input.name}`,
        instanceID: `i-${input.name}`,
        name: input.name,
        platform: input.platform ?? "darwin",
        hub: input.hub ?? false,
        speed: input.speed ?? "normal",
        capabilities: input.capabilities ?? {},
        capacity: input.capacity ?? { memMb: 32_768, cpuMilli: 8_000, builds: 1, android: 0, ios: 0 },
        ...(input.secrets ? { secrets: input.secrets } : {}),
        ...(input.presence ? { presence: input.presence } : {}),
        ...(input.brake ? { brake: input.brake } : {}),
        ...(input.ports ? { ports: input.ports } : {}),
        ...(input.docker === undefined ? {} : { docker: input.docker }),
        ...(input.phones ? { phones: input.phones } : {}),
        ...(input.hardware ? { hardware: input.hardware } : {}),
        ...(input.prefix ? { prefix: input.prefix } : {}),
      }
      const db = new Database(":memory:")
      const core = build(config, db)
      const machine: SimMachine = { name: input.name, core, db, config, awake: true }
      machines.set(input.name, machine)
      if (config.hub) hub = machine
      return machine
    },
    /** How a part runs; with `attempt`, only that attempt (a new attempt runs differently). */
    script: (job: string, part: string, script: Script, attempt?: number) =>
      scripts.set(attempt === undefined ? `${job}/${part}` : `${job}/${part}#${attempt}`, script),
    /** The Bancada process of a machine dies and comes back on the same database; its executions go on. */
    restart: (name: string) => {
      const machine = machines.get(name)!
      machine.core = build(machine.config, machine.db)
      return machine.core
    },
    /**
     * A machine's database is replaced and its process starts over on it: an empty one (a wiped folder, whose
     * executions go with it) or a copy from before (`Database.deserialize`), whose executions go on.
     */
    replaceDb: (name: string, db: Database = new Database(":memory:")) => {
      const machine = machines.get(name)!
      const wiped = db.query("SELECT name FROM sqlite_master WHERE name = 'attempt'").get() === null
      machine.db = db
      machine.core = build(machine.config, db)
      if (wiped) for (const [run, execution] of runs) if (run.startsWith(`${name}:`)) execution.cancelled = true
      return machine.core
    },
    /** A machine sleeps (nothing of it runs, its executions' awake time stops) or wakes. */
    sleep: (name: string, asleep: boolean) => {
      machines.get(name)!.awake = !asleep
    },
    /** A reading of a machine (its brake, its owner's presence), as its process takes one every 5 s. */
    observe: (name: string, reading: Omit<Reading, "at">) =>
      machines.get(name)!.core.observe({ at: clock.now, ...reading }),
    /** One round of one machine, nothing else: for a state a full step would already undo. */
    round: (name: string) => round(machines.get(name)!),
    /** States a part of the hub's queue went through, in order and without repeats. */
    seen: (job: string, part: string) => facts.states.get(`${job}/${part}`) ?? [],
    submit: (machine: string, job: NewJob) => {
      facts.submitted.set(job.id, { machine, job })
      return machines.get(machine)!.core.submit(job)
    },
    /** Moves virtual time on, `step` at a time: ticks, one call per machine, deliveries, notices, invariants. */
    advance: async (ms: number, step = 1_000) => {
      for (const end = clock.now + ms; clock.now < end; ) {
        clock.now += step
        for (const [name, run] of runs) {
          const finished = "vanishMs" in run.script || run.awakeMs >= run.script.buildMs + run.script.runMs
          if (machines.get(name.slice(0, name.indexOf(":")))?.awake) run.awakeMs += step
          else if (!finished && !run.cancelled) run.sleptMs += step
        }
        starting
          .filter((start) => start.at <= clock.now)
          .forEach((start) => {
            starting.splice(starting.indexOf(start), 1)
            start.resolve()
          })
        for (const machine of machines.values()) if (machine.awake) await round(machine)
        for (const machine of machines.values()) if (machine.awake && machine !== hub) exchange(machine)
        inflight.sort((a, b) => a.at - b.at || a.order - b.order)
        while (inflight[0] && inflight[0].at <= clock.now) inflight.shift()!.run()
        for (const machine of machines.values()) if (machine.awake) deliver(machine)
        record()
        invariants()
      }
    },
    /**
     * What must hold once everything settled: each job noticed exactly once and its result telling the truth; no
     * reservation or attempt left, every outbox empty, no part of the hub's queue unfinished, every request delivered
     * at its origin, nothing in `dead_letter`.
     */
    settle: () => {
      invariants()
      for (const machine of machines.values()) {
        const count = (sql: string) => machine.db.query<{ n: number }, []>(sql).get()!.n
        const left = {
          "active leases": count("SELECT COUNT(*) AS n FROM lease WHERE state = 'active'"),
          // After delivery the executor keeps nothing of the job (D9).
          "attempts kept after delivery": count("SELECT COUNT(*) AS n FROM attempt"),
          "outbox messages": count("SELECT COUNT(*) AS n FROM outbox"),
          "dead letters": count("SELECT COUNT(*) AS n FROM dead_letter"),
          "requests not delivered": count("SELECT COUNT(*) AS n FROM job WHERE state <> 'entregue'"),
          "unfinished parts in the queue": count(
            "SELECT COUNT(*) AS n FROM hub_part WHERE state NOT IN ('concluido', 'perdido', 'cancelado', 'invalido')",
          ),
        }
        const unsettled = Object.entries(left).filter(([, n]) => n > 0)
        if (unsettled.length)
          throw new Error(
            `${machine.name} did not settle: ${unsettled.map(([what, n]) => `${n} ${what}`).join(", ")}\n${logs.join("\n")}`,
          )
      }
      for (const job of facts.submitted.keys()) {
        if (facts.notices.get(job) !== 1) throw new Error(`${job} was noticed ${facts.notices.get(job) ?? 0} times`)
        for (const result of facts.delivered.get(job) ?? []) {
          if (!result.outcome?.approved) continue
          const script = scriptOf(job, result.part, result.attempts)
          if (!script || "vanishMs" in script) throw new Error(`${job}/${result.part} approved without a run`)
          const answered = new Set(result.outcome.scenarios.map((scenario) => scenario.id))
          if (result.outcome.lost.length > 0 || !result.outcome.planned.every((id) => answered.has(id)))
            throw new Error(`${job}/${result.part} approved without a result for every planned scenario`)
        }
      }
    },
  }
}

export type World = ReturnType<typeof createWorld>

function sha256(data: Uint8Array) {
  return new Bun.CryptoHasher("sha256").update(data).digest("hex")
}

function concat(a: Uint8Array, b: Uint8Array) {
  const joined = new Uint8Array(a.byteLength + b.byteLength)
  joined.set(a)
  joined.set(b, a.byteLength)
  return joined
}

/** The value, or the core's refusal it threw. */
function attempt<T>(run: () => T): T | CoreError {
  try {
    return run()
  } catch (error) {
    if (error instanceof CoreError) return error
    throw error
  }
}

/** mulberry32: a small deterministic generator, so a failing seed can be replayed. */
function rng(seed: number) {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let value = state
    value = Math.imul(value ^ (value >>> 15), value | 1)
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61)
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296
  }
}
