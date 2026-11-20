// Simulation of several Bancada cores in one process (plan, section 15.2): each with an in-memory database, a virtual
// clock, a scripted launcher and a network that drops, delays, duplicates and partitions. Every step checks the
// invariants; `settle` checks the ones that hold only at the end.
import { Database } from "bun:sqlite"
import type { Reading } from "../../src/bancada/daemon/brake"
import { CoreError, createCore, type Core, type Machine, type timings } from "../../src/bancada/daemon/core"
import type { AttemptKey, Launch, Launcher, Placed, Status } from "../../src/bancada/daemon/executor"
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

  const launcher = (machine: string): Launcher => ({
    start: async (launch: Launch) => {
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
      if (elapsed < run.script.buildMs + run.script.runMs) return { state: "rodando" }
      // The project's two files, as a real run writes them.
      return {
        state: "done",
        ending: {
          stage: "run",
          exit: run.script.exit,
          ...(run.script.fell ? { fell: run.script.fell } : {}),
          ...(run.sleptMs > 0 ? { sleptMs: run.sleptMs } : {}),
          ...(run.only ? { only: run.only } : {}),
          planned: { versao: 1, cenarios: run.script.planned.map((id) => ({ id })) },
          summary: {
            versao: 1,
            cenarios: run.script.scenarios.map((item) => ({
              id: item.id,
              resultado: item.result,
              ...(item.message ? { mensagem: item.message } : {}),
              ...(item.device ? { aparelho: item.device } : {}),
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
    cleanup: async () => {},
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
