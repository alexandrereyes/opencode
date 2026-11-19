// Simulation of several Bancada cores in one process (plan, section 15.2): each with an in-memory database, a virtual
// clock, a scripted launcher and a network that drops, delays, duplicates and partitions. Every step checks the
// invariants; `settle` checks the ones that hold only at the end.
import { Database } from "bun:sqlite"
import { createCore, type Core, type Machine } from "../../src/bancada/daemon/core"
import type { AttemptKey, Launch, Launcher, Status } from "../../src/bancada/daemon/executor"
import type { NewJob } from "../../src/bancada/daemon/origin"
import type { BancadaProtocol } from "../../src/bancada/protocol"

/** How a part's execution goes, on virtual time. */
export type Script =
  | {
      readonly buildMs: number
      readonly runMs: number
      readonly exit: number
      readonly planned: ReadonlyArray<string>
      readonly scenarios: ReadonlyArray<BancadaProtocol.Scenario>
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
  readonly core: Core
  readonly db: Database
  readonly config: Machine
  awake: boolean
}

export function createWorld(options: {
  readonly seed: number
  readonly toHub?: Faults
  readonly toMachine?: Faults
  /** Virtual-time windows during which everything between a machine and the hub is lost. */
  readonly partitions?: ReadonlyArray<{ readonly machine: string; readonly from: number; readonly to: number }>
}) {
  const clock = { now: 1_000_000 }
  const random = rng(options.seed)
  const machines = new Map<string, SimMachine>()
  const scripts = new Map<string, Script>()
  const runs = new Map<string, { readonly startedAt: number; readonly script: Script }>()
  const facts = {
    starts: new Map<string, number>(),
    notices: new Map<string, number>(),
    results: new Map<string, Set<number>>(),
    submitted: new Map<string, { readonly machine: string; readonly job: NewJob }>(),
    delivered: new Map<string, ReadonlyArray<BancadaProtocol.PartResult>>(),
    /** Offers an executor refused, by machine and sequence number: the hub offered more than the machine had. */
    refusals: new Set<string>(),
  }
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

  const launcher = (machine: string): Launcher => ({
    start: async (launch: Launch) => {
      const name = key(launch)
      if (runs.has(`${machine}:${name}`)) return
      const script = scripts.get(`${launch.job}/${launch.part}`)
      if (!script) throw new Error(`no script for ${launch.job}/${launch.part}`)
      runs.set(`${machine}:${name}`, { startedAt: clock.now, script })
      const part = `${launch.job}/${launch.part}`
      facts.starts.set(part, (facts.starts.get(part) ?? 0) + 1)
    },
    status: async (attempt: AttemptKey): Promise<Status> => {
      const run = runs.get(`${machine}:${key(attempt)}`)
      if (!run) return { state: "gone", reason: "no execution" }
      const elapsed = clock.now - run.startedAt
      if ("vanishMs" in run.script)
        return elapsed < run.script.vanishMs ? { state: "rodando" } : { state: "gone", reason: "a execução morreu" }
      if (elapsed < run.script.buildMs) return { state: "compilando" }
      if (elapsed < run.script.buildMs + run.script.runMs) return { state: "rodando" }
      return { state: "done", exit: run.script.exit, planned: run.script.planned, scenarios: run.script.scenarios }
    },
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
    const input = wire(machine.core.outgoing())
    for (const delay of faults(options.toHub, machine.name))
      later(delay, () => {
        if (!hub?.awake) return
        input.out.messages
          .filter((message) => message.body.type === "offer.reply" && !message.body.accepted)
          .forEach((message) => facts.refusals.add(`${machine.name}:${message.seq}`))
        const output = wire(hub.core.sync(input))
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

  const invariants = () => {
    for (const machine of machines.values()) {
      const used = machine.db
        .query<
          { android: number; ios: number },
          []
        >("SELECT COALESCE(SUM(android), 0) AS android, COALESCE(SUM(ios), 0) AS ios FROM lease WHERE state = 'active'")
        .get()!
      if (used.android > machine.config.capacity.android || used.ios > machine.config.capacity.ios)
        throw new Error(`${machine.name} reserved beyond its budget: ${JSON.stringify(used)}`)
    }
    for (const [job, count] of facts.notices) if (count > 1) throw new Error(`${job} was noticed ${count} times`)
    for (const [job, seqs] of facts.results) if (seqs.size > 1) throw new Error(`${job} closed ${seqs.size} times`)
    for (const [part, count] of facts.starts)
      if (count > 1) throw new Error(`${part} started ${count} times without a retry`)
  }

  return {
    clock,
    machines,
    facts,
    addMachine: (input: { readonly name: string; readonly hub?: boolean } & Partial<Omit<Machine, "hub" | "name">>) => {
      const config: Machine = {
        machineID: `m-${input.name}`,
        instanceID: `i-${input.name}`,
        name: input.name,
        platform: input.platform ?? "darwin",
        hub: input.hub ?? false,
        speed: input.speed ?? "normal",
        capabilities: input.capabilities ?? {},
        capacity: input.capacity ?? { memMb: 0, cpuMilli: 0, builds: 1, android: 0, ios: 0 },
      }
      const db = new Database(":memory:")
      const core = createCore({ db, now: () => clock.now, random: id, machine: config, launcher: launcher(input.name) })
      const machine: SimMachine = { name: input.name, core, db, config, awake: true }
      machines.set(input.name, machine)
      if (config.hub) hub = machine
      return machine
    },
    script: (job: string, part: string, script: Script) => scripts.set(`${job}/${part}`, script),
    submit: (machine: string, job: NewJob) => {
      facts.submitted.set(job.id, { machine, job })
      return machines.get(machine)!.core.submit(job)
    },
    /** Moves virtual time on, `step` at a time: ticks, one call per machine, deliveries, notices, invariants. */
    advance: async (ms: number, step = 1_000) => {
      for (const end = clock.now + ms; clock.now < end; ) {
        clock.now += step
        for (const machine of machines.values()) if (machine.awake) await machine.core.tick()
        for (const machine of machines.values()) if (machine.awake && machine !== hub) exchange(machine)
        inflight.sort((a, b) => a.at - b.at || a.order - b.order)
        while (inflight[0] && inflight[0].at <= clock.now) inflight.shift()!.run()
        for (const machine of machines.values()) if (machine.awake) deliver(machine)
        invariants()
      }
    },
    /** What must hold once everything settled: each job noticed exactly once, and its result tells the truth. */
    settle: () => {
      invariants()
      for (const job of facts.submitted.keys()) {
        if (facts.notices.get(job) !== 1) throw new Error(`${job} was noticed ${facts.notices.get(job) ?? 0} times`)
        for (const result of facts.delivered.get(job) ?? []) {
          const script = scripts.get(`${job}/${result.part}`)
          if (!result.outcome?.approved) continue
          if (!script || "vanishMs" in script) throw new Error(`${job}/${result.part} approved without a run`)
          const answered = new Set(script.scenarios.map((scenario) => scenario.id))
          if (!script.planned.every((scenario) => answered.has(scenario)) || script.exit !== 0)
            throw new Error(`${job}/${result.part} approved without a result for every planned scenario`)
        }
      }
    },
  }
}

export type World = ReturnType<typeof createWorld>

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
