import type { Database } from "bun:sqlite"
import fs from "node:fs/promises"
import net from "node:net"
import path from "node:path"
import { Option, Schema } from "effect"
import { defaults, type Phone, type Range } from "../../machine-config.js"
import type { BancadaProtocol } from "../../protocol.js"
import { BancadaResults } from "../../results.js"
import type { Launcher, Placed } from "../executor.js"
import { seat } from "../scheduler.js"
import { deviceFor, type DeviceKind, type Profile } from "./types.js"

const decodePlanned = Schema.decodeUnknownOption(BancadaResults.Planned)

/**
 * The devices of this machine's attempts (`docs/bancada.md`, "Devices"): chosen or created for a part when its attempt
 * starts, made ready while it builds, written to its `devices.json`, watched every 10 s while it runs (a device mute
 * for 60 s or dead fell: the part's `caiu` file names it), and given back with the attempt's folder. Only devices of
 * the `device` table, named with the machine's prefix, are ever touched.
 */

/** One kind of device, as the pool drives it (`devices/android-local.ts`, `devices/ios.ts`). */
export type Driver = {
  readonly kind: DeviceKind
  /** What a part's device spec becomes here (an image, a runtime and model), or why it cannot. */
  readonly choose: (spec: BancadaProtocol.DeviceSpec, profile: Profile) => Promise<Choice | string>
  /** Ready for the project, from clean: created when missing. What goes in `devices.json`, and how to watch it. */
  readonly ready: (
    device: Device,
    slot: Range,
    key: Placed,
  ) => Promise<{ readonly view: Record<string, unknown>; readonly run: Running }>
  readonly health: (device: Device, run: Running) => Promise<"ok" | "morto" | "mudo">
  readonly giveBack: (device: Device, run: Running) => Promise<void>
  /**
   * Given back clean but left running, to be handed to the next part (`ready` finds it running): false when it is
   * not well enough for that (then it is given back as usual).
   */
  readonly keep?: (device: Device, run: Running) => Promise<boolean>
}

/** A choice of device: what makes two devices interchangeable (`key`), and how to name the `n`-th of them. */
export type Choice = {
  readonly key: string
  readonly spec: Readonly<Record<string, unknown>>
  readonly name: (n: number) => string
}

export type Device = {
  readonly id: string
  readonly kind: DeviceKind
  readonly profile: Profile
  readonly spec: Readonly<Record<string, unknown>>
}

/** How a started device is known again: its serial and console, its process (pid and start time), its UDID. */
export type Running = {
  readonly serial?: string
  readonly console?: number
  readonly pid?: number
  readonly started?: string
  readonly udid?: string
  /** An emulator's own container (host-6). */
  readonly container?: string
}

type Row = {
  readonly id: string
  readonly kind: DeviceKind
  readonly profile: Profile
  readonly choice: string
  readonly spec: string
  readonly state: "criado" | "ligando" | "em_uso" | "devolvendo" | "caiu" | "aquecido" | "isolado"
  readonly running: string | null
  readonly attempt: string | null
  readonly part_dir: string | null
  readonly falls: number
  readonly quarantined_until: number | null
  readonly mute_since: number | null
  readonly last_used_at: number | null
}

const muteMs = 60_000
const quarantineMs = 30 * 60_000

export function makeDevicePool(input: {
  readonly db: Database
  readonly now: () => number
  readonly drivers: () => Partial<Record<"android" | "ios", Driver>>
  /** The console ports of local emulators (`portas.emulador`), in pairs. */
  readonly emulatorPorts: Range
  readonly simslim: () => boolean
  /** The phones of this machine (`devices/physical.ts`) and giving a test's phone back (its hold, `holds.ts`). */
  readonly phone?: {
    readonly find: (alias: string) => Phone | undefined
    readonly serial: (alias: string) => string | undefined
    readonly connected: (alias: string) => boolean
    readonly done: (attempt: string) => void
    readonly machine: () => string
  }
  /** `[android.docker]` (host-6): Android devices are emulators in containers. */
  readonly docker?: boolean
  /**
   * How long a device given back clean stays running for the next part (`aquecido_min`, host-6's emulators in
   * containers); without it, every device is stopped when given back.
   */
  readonly warmMs?: number
  /** Whether that many running devices of a platform, nobody's, still fit in this machine's budget (`executor.ts`). */
  readonly warmFits?: (platform: "android" | "ios", count: number) => boolean
  /** Gives back what an attempt was granted beyond the devices its plan can use (`executor.ts`). */
  readonly shrink?: (key: Placed, devices: number) => void
  /** Grants an attempt more of the devices its plan can use, as many as fit now: its count after (`executor.ts`). */
  readonly grow?: (key: Placed, devices: number) => number
  /** How often the pool looks for a part's plan, and for room for the devices it lacks while the others start. */
  readonly planPollMs?: number
  /** Whether discovery ran once: before that this machine's drivers are not known (right after a start). */
  readonly discovered?: () => boolean
  /** An exception for the apps and the log (`alerts.ts`). */
  readonly alert?: (key: string, text: string) => void
  readonly log: (line: string) => void
}) {
  const db = input.db
  const tasks = new Map<string, Promise<void>>()
  const byAttempt = db.query<Row, [string]>("SELECT * FROM device WHERE attempt = ?")
  const using = db.query<Row, []>("SELECT * FROM device WHERE state = 'em_uso'")
  const attemptOf = (key: Placed) => `${key.job}/${key.part}/${key.attempt}`
  const set = (id: string, fields: Record<string, string | number | null>) =>
    db.run(
      `UPDATE device SET ${Object.keys(fields)
        .map((name) => `${name} = ?`)
        .join(", ")} WHERE id = ?`,
      [...Object.values(fields), id],
    )
  const device = (row: Row): Device => ({
    id: row.id,
    kind: row.kind,
    profile: row.profile,
    spec: JSON.parse(row.spec),
  })

  /** The free devices of a choice first (running ones first), then new names: never two attempts on one device. */
  const take = (choice: Choice, kind: DeviceKind, profile: Profile, count: number, attempt: string, dir: string) =>
    db.transaction(() => {
      const free = db
        .query<
          Row,
          [string, number]
        >("SELECT * FROM device WHERE choice = ? AND state IN ('aquecido', 'criado') AND COALESCE(quarantined_until, 0) <= ? ORDER BY state = 'aquecido' DESC, id")
        .all(choice.key, input.now())
        .slice(0, count)
      const names = new Set(
        db
          .query<{ id: string }, []>("SELECT id FROM device")
          .all()
          .map((row) => row.id),
      )
      const fresh = Array.from({ length: count - free.length }, () => {
        const n = Array.from({ length: names.size + count + 1 }, (_, index) => index + 1).find(
          (index) => !names.has(choice.name(index)),
        )!
        names.add(choice.name(n))
        db.run(
          "INSERT INTO device (id, kind, profile, choice, spec, state, falls, last_used_at) VALUES (?, ?, ?, ?, ?, 'criado', 0, ?)",
          [choice.name(n), kind, profile, choice.key, JSON.stringify(choice.spec), input.now()],
        )
        return choice.name(n)
      })
      const ids = [...free.map((row) => row.id), ...fresh]
      ids.forEach((id) =>
        set(id, { state: "ligando", attempt, part_dir: dir, mute_since: null, last_used_at: input.now() }),
      )
      return ids
    })()

  /**
   * The block of the attempt's ports a device takes as it starts: the one it took before (started again), else the
   * first nobody took.
   */
  const claim = (lease: string, id: string) =>
    db.transaction(() => {
      const block = db
        .query<
          { rowid: number; start: number; end: number },
          [string, string, string]
        >("SELECT rowid, port_start AS start, port_end AS end FROM lease_device WHERE lease_id = ? AND (device_id IS NULL OR device_id = ?) ORDER BY device_id = ? DESC, rowid LIMIT 1")
        .get(lease, id, id)
      if (block) db.run("UPDATE lease_device SET device_id = ? WHERE rowid = ?", [id, block.rowid])
      return block ? { start: block.start, end: block.end } : undefined
    })()

  const prepare = async (key: Placed, dir: string) => {
    const row = db
      .query<
        {
          spec: string
          devices: number
          per_device: number | null
          lease_id: string
          phone_hold: string | null
          only_scenarios: string | null
        },
        [string, string, number]
      >(
        "SELECT spec, devices, per_device, lease_id, phone_hold, only_scenarios FROM attempt WHERE job_id = ? AND part = ? AND n = ?",
      )
      .get(key.job, key.part, key.attempt)
    if (!row || (row.devices === 0 && !row.phone_hold)) return
    const spec: BancadaProtocol.PartSpec = JSON.parse(row.spec)
    if (spec.platform === "none") return
    const fail = async (reason: string) => {
      input.log(`devices of ${attemptOf(key)} not ready: ${reason}`)
      await Bun.write(path.join(dir, "devices.error"), `${reason}\n`)
    }
    const write = async (views: ReadonlyArray<Record<string, unknown>>) => {
      // One device per line: a project's `run` in plain shell can read it.
      await Bun.write(
        path.join(dir, "devices.json.tmp"),
        `{ "versao": 1, "aparelhos": [\n${views.map((view) => `  ${JSON.stringify(view)}`).join(",\n")}\n] }\n`,
      )
      await fs.rename(path.join(dir, "devices.json.tmp"), path.join(dir, "devices.json"))
    }
    // The phone its hold took at the offer, then the devices it asks for besides.
    const held = row.phone_hold ? phone(key, dir, row.phone_hold, row.lease_id) : undefined
    if (typeof held === "string") return fail(held)
    if (row.devices === 0) return write(held ? [held] : [])
    // Right after a start the drivers come with the first discovery: a part waits for it, a minute at most.
    for (let waited = 0; input.discovered && !input.discovered() && waited < 60; waited++) await Bun.sleep(1_000)
    const driver = input.drivers()[spec.platform]
    const chosen = deviceFor(spec.platform, spec.device, { docker: input.docker ?? false, simslim: input.simslim() })
    if (!driver || !chosen) return fail(`esta máquina não liga aparelhos ${spec.platform}`)
    const choice = await driver.choose(spec.device, chosen.profile)
    if (typeof choice === "string") return fail(choice)
    const start = (ids: ReadonlyArray<string>) =>
      ids.map(async (id) => {
        // Its block of ports is taken before anything waits: devices starting together never share one.
        const slot = claim(row.lease_id, id)
        if (!slot) throw new Error("sem portas livres para o aparelho")
        const one = byAttempt.all(attemptOf(key)).find((item) => item.id === id)!
        const ready = await driver.ready(device(one), slot, key)
        set(id, { running: JSON.stringify(ready.run) })
        return ready.view
      })
    // With a plan, its minimum starts while the part builds; once the plan said its scenarios, as many as they are
    // worth (`usefulDevices`): what it was granted beyond goes back unstarted, what it lacks is asked for (`grow`) every
    // round while the devices it has still start, and it runs with what it has once they are all ready.
    // Running devices nobody needs give way to this part's reservation, when both do not fit.
    await trim()
    const plan = await planned(dir)
    const early = plan ? Math.min(row.devices, Math.max(1, spec.devices.min)) : row.devices
    const ids = take(choice, chosen.kind, chosen.profile, early, attemptOf(key), dir)
    const starts = start(ids)
    const useful = plan ? await usefulDevices(key, dir, row, spec.devices.max) : undefined
    const wanted = useful === undefined ? early : Math.max(early, useful)
    if (wanted < row.devices) {
      input.shrink?.(key, wanted)
      input.log(`${attemptOf(key)} uses ${wanted} of the ${row.devices} devices granted (its plan)`)
    }
    const count = { granted: Math.min(wanted, row.devices), started: early, asked: false }
    for (;;) {
      const granted =
        count.granted < wanted && input.grow ? Math.max(count.granted, input.grow(key, wanted)) : count.granted
      if (granted > count.granted || (!count.asked && granted < wanted)) {
        count.asked = true
        input.log(`${attemptOf(key)} has ${granted} of the ${wanted} devices its scenarios are worth`)
      }
      // The devices it was granted now may be some of those running nobody uses: they stay for it.
      if (granted > count.granted) await trim()
      count.granted = granted
      if (count.granted > count.started) {
        const more = take(choice, chosen.kind, chosen.profile, count.granted - count.started, attemptOf(key), dir)
        ids.push(...more)
        starts.push(...start(more))
        count.started = count.granted
      }
      const settled = await Promise.race([
        Promise.allSettled(starts).then(() => true),
        Bun.sleep(input.planPollMs ?? 1_000).then(() => false),
      ])
      if (settled) break
    }
    const started = await Promise.allSettled(starts)
    const failed = started.flatMap((item) => (item.status === "rejected" ? [String(item.reason)] : []))
    if (failed.length > 0) {
      // What did start goes back with the attempt (`release`); the part ends with the reason.
      ids.forEach((id) => set(id, { state: "em_uso" }))
      return fail(failed[0]!.replace(/^Error: /, ""))
    }
    ids.forEach((id) => set(id, { state: "em_uso" }))
    const views = started.flatMap((item) => (item.status === "fulfilled" ? [item.value] : []))
    await write([...views, ...(held ? [held] : [])])
    input.log(
      `devices of ${attemptOf(key)} ready: ${ids.join(", ")}${held ? ` and the phone ${String(held.apelido)}` : ""}`,
    )
  }

  /**
   * A test's phone (`docs/bancada.md`, "Phones"): the one its hold took, as it is connected now, for its
   * `devices.json`; why not, when it is not connected. Nothing is done on the phone: not cleared, restarted nor
   * stopped, before or after.
   */
  const phone = (key: Placed, dir: string, hold: string, lease: string) => {
    const target = db.query<{ target: string }, [string]>("SELECT target FROM hold WHERE id = ?").get(hold)
    const alias = target ? (JSON.parse(target.target) as { device: string }).device : undefined
    const found = alias ? input.phone?.find(alias) : undefined
    const serial = alias ? input.phone?.serial(alias) : undefined
    if (!found || !serial) return `o celular ${alias ?? ""} não está conectado`
    const slot = claim(lease, `fisico:${found.alias}`)
    db.run(
      "INSERT INTO device (id, kind, profile, choice, spec, state, running, attempt, part_dir, falls, last_used_at) VALUES (?, ?, 'estoque', 'fisico', ?, 'em_uso', ?, ?, ?, 0, ?) ON CONFLICT (id) DO UPDATE SET state = 'em_uso', running = excluded.running, attempt = excluded.attempt, part_dir = excluded.part_dir, mute_since = NULL, last_used_at = excluded.last_used_at",
      [
        `fisico:${found.alias}`,
        `${found.platform}-fisico`,
        JSON.stringify({ alias: found.alias }),
        JSON.stringify({ serial }),
        attemptOf(key),
        dir,
        input.now(),
      ],
    )
    const view = {
      id: found.id,
      tipo: `${found.platform}-fisico`,
      plataforma: found.platform,
      nome: found.name,
      apelido: found.alias,
      serial: found.platform === "android" ? serial : null,
      udid: found.platform === "ios" ? found.id : null,
      adb: found.platform === "android" ? { host: "127.0.0.1", porta: 5037 } : null,
      etiquetas: [...found.tags],
      contasReais: found.realAccounts,
      ...(slot ? { portas: { inicio: slot.start, fim: slot.end } } : {}),
      host: null,
      maquina: input.phone!.machine(),
    }
    input.log(`the phone ${found.alias} (${serial}) is ${attemptOf(key)}'s`)
    return view
  }

  /**
   * How many devices a part's scenarios are worth, once its plan said them (`planned.json`; a run again of some
   * scenarios, only those): never more than its groups (scenarios of one `grupo` share a device, one without a group is
   * a group of its own), one per `per_device` scenarios (decided at its admission), at most its test's maximum.
   * Undefined when the part ended or its attempt is gone first; what it was granted when it reached its run without a
   * plan's word.
   */
  const usefulDevices = async (
    key: Placed,
    dir: string,
    row: { readonly devices: number; readonly per_device: number | null; readonly only_scenarios: string | null },
    max: number,
  ) => {
    const group = path.dirname(path.dirname(dir))
    const live = db.query<{ state: string }, [string, string, number]>(
      "SELECT state FROM attempt WHERE job_id = ? AND part = ? AND n = ? AND state IN ('aceito', 'compilando', 'rodando')",
    )
    const asked = row.only_scenarios ? new Set(JSON.parse(row.only_scenarios) as string[]) : undefined
    for (;;) {
      const plan = Option.getOrUndefined(
        decodePlanned(
          await Bun.file(path.join(dir, "out", "planned.json"))
            .json()
            .catch(() => undefined),
        ),
      )
      if (plan) {
        const scenarios = plan.cenarios.filter((scenario) => !asked || asked.has(scenario.id))
        const groups = new Set(scenarios.map((scenario) => scenario.grupo ?? `\u0000${scenario.id}`)).size
        return Math.min(max, groups, Math.ceil(scenarios.length / (row.per_device ?? defaults.scenariosPerDevice)))
      }
      if (await Bun.file(path.join(dir, "status.json")).exists()) return undefined
      if (!live.get(key.job, key.part, key.attempt)) return undefined
      const events = await Bun.file(path.join(group, "events.jsonl"))
        .text()
        .catch(() => "")
      if (events.includes('"devices.wait"')) return row.devices
      await Bun.sleep(input.planPollMs ?? 500)
    }
  }

  /** Gives back every device of an attempt, stopped and clean; two falls in a row put one 30 min aside. */
  const release = async (attempt: string) => {
    for (const row of byAttempt.all(attempt).filter((item) => item.kind.endsWith("-fisico"))) {
      // A phone goes back as it is: only its hold ends.
      input.phone?.done(attempt)
      set(row.id, { state: "criado", running: null, attempt: null, part_dir: null })
    }
    for (const row of byAttempt.all(attempt)) {
      set(row.id, { state: "devolvendo" })
      const driver = input.drivers()[row.kind.startsWith("ios") ? "ios" : "android"]
      const running: Running = row.running ? JSON.parse(row.running) : {}
      // Clean and running for the next part, for `warmMs` (one that fell is never kept).
      const warm =
        input.warmMs !== undefined && row.state !== "caiu" && driver?.keep
          ? await driver.keep(device(row), running).catch(() => false)
          : false
      if (warm) {
        set(row.id, { state: "aquecido", attempt: null, part_dir: null, falls: 0, last_used_at: input.now() })
        input.log(`${row.id} stays running for ${Math.round(input.warmMs! / 60_000)} min`)
        continue
      }
      const failure = await (driver ? driver.giveBack(device(row), running) : Promise.resolve()).then(
        () => undefined,
        (error: unknown) => (error instanceof Error ? error.message : String(error)),
      )
      const fell = row.state === "caiu"
      const falls = fell ? row.falls + 1 : 0
      // Not given back: set apart from the attempt (whose reservation and folder go back) and from every part, its
      // port still held, until a later round gives it back.
      set(row.id, {
        state: failure === undefined ? "criado" : "isolado",
        running: failure === undefined ? null : row.running,
        attempt: null,
        part_dir: null,
        falls,
        quarantined_until: falls >= 2 ? input.now() + quarantineMs : row.quarantined_until,
      })
      if (failure !== undefined) {
        input.log(`giving back ${row.id} failed: ${failure}; set apart until it can be`)
        input.alert?.(`isolado:${row.id}`, `${row.id} não pôde ser devolvido (${failure}); ficou separado`)
      }
      if (falls >= 2) input.log(`${row.id} fell twice in a row: 30 min aside`)
    }
  }

  /** A running device nobody uses, stopped: given back as any other. */
  const stop = async (row: Row) => {
    set(row.id, { state: "devolvendo" })
    const driver = input.drivers()[row.kind.startsWith("ios") ? "ios" : "android"]
    const given = await (
      driver ? driver.giveBack(device(row), row.running ? JSON.parse(row.running) : {}) : Promise.resolve()
    )
      .then(() => true)
      .catch((error: unknown) => {
        input.log(`stopping ${row.id} failed: ${String(error)}`)
        return false
      })
    set(row.id, given ? { state: "criado", running: null } : { state: "aquecido" })
  }
  const warmRows = db.query<Row, []>("SELECT * FROM device WHERE state = 'aquecido' ORDER BY last_used_at, id")
  const isolated = db.query<Row, []>("SELECT * FROM device WHERE state = 'isolado' ORDER BY id")
  /**
   * Running devices nobody uses count in the budget: beyond what the attempts accepted and not yet given their devices
   * will take, the oldest stop while they do not fit.
   */
  const trim = async () => {
    if (!input.warmFits) return
    for (const platform of ["android", "ios"] as const) {
      const warm = warmRows.all().filter((row) => row.kind.startsWith(platform))
      if (warm.length === 0) continue
      const pending = db
        .query<
          { count: number },
          [string, string]
        >("SELECT (SELECT COALESCE(SUM(a.devices), 0) FROM attempt a JOIN lease l ON l.id = a.lease_id WHERE l.state = 'active' AND a.state IN ('aceito', 'compilando', 'rodando') AND json_extract(a.spec, '$.platform') = ?) - (SELECT COUNT(*) FROM device WHERE attempt IS NOT NULL AND kind LIKE ? AND kind NOT LIKE '%-fisico') AS count")
        .get(platform, `${platform}%`)!.count
      const spare = warm.slice(0, Math.max(0, warm.length - Math.max(0, pending)))
      while (spare.length > 0 && !input.warmFits(platform, spare.length)) await stop(spare.shift()!)
    }
  }

  /** The ports handed out one after the other (`consolePort`). */
  const ports = { chain: Promise.resolve() as Promise<unknown> }

  const run = (id: string, work: () => Promise<void>) => {
    if (tasks.has(id)) return
    const task = work()
      .catch((error: unknown) => input.log(`device task ${id} failed: ${String(error)}`))
      .finally(() => tasks.delete(id))
    tasks.set(id, task)
  }

  return {
    /** The devices of a part, made ready off the round (`devices.json`, or `devices.error` with the reason). */
    prepare: (key: Placed, dir: string) => run(`prepare:${attemptOf(key)}`, () => prepare(key, dir)),
    /** Whether a part's devices are being prepared or given back by this process. */
    busy: (key: Placed) =>
      tasks.has(`prepare:${attemptOf(key)}`) ||
      tasks.has(`release:${attemptOf(key)}`) ||
      byAttempt.all(attemptOf(key)).length > 0,
    preparing: (key: Placed) => tasks.has(`prepare:${attemptOf(key)}`),
    /** Once every preparation and giving back started so far has ended. */
    settled: () => Promise.all([...tasks.values()]).then(() => undefined),
    /** Gives back the devices of attempts no longer live. */
    reap: (live: ReadonlyArray<Placed>) => {
      const alive = new Set(live.map(attemptOf))
      const held = db
        .query<{ attempt: string }, []>("SELECT DISTINCT attempt FROM device WHERE attempt IS NOT NULL")
        .all()
      held
        .filter((row) => !alive.has(row.attempt) && !tasks.has(`prepare:${row.attempt}`))
        .forEach((row) => run(`release:${row.attempt}`, () => release(row.attempt)))
    },
    /**
     * Every 10 s: a device in use that is dead, or mute for 60 s, fell; its part's `caiu` file names it. A running
     * device nobody took for `warmMs` stops, and so do the oldest while they do not fit in the budget.
     */
    watch: async () => {
      for (const row of warmRows.all().filter((item) => input.now() - (item.last_used_at ?? 0) >= (input.warmMs ?? 0)))
        await stop(row)
      await trim()
      // Set apart when it could not be given back: tried again every round, quietly, until it is.
      for (const row of isolated.all()) {
        const driver = input.drivers()[row.kind.startsWith("ios") ? "ios" : "android"]
        if (!driver) continue
        const given = await driver.giveBack(device(row), row.running ? JSON.parse(row.running) : {}).then(
          () => true,
          () => false,
        )
        if (!given) continue
        set(row.id, { state: "criado", running: null })
        input.log(`${row.id}, set apart, was given back`)
      }
      for (const row of using.all()) {
        if (row.kind.endsWith("-fisico")) {
          const alias = (JSON.parse(row.spec) as { alias: string }).alias
          if (input.phone?.connected(alias)) {
            if (row.mute_since !== null) set(row.id, { mute_since: null })
            continue
          }
          if (row.mute_since === null || input.now() - row.mute_since < muteMs) {
            if (row.mute_since === null) set(row.id, { mute_since: input.now() })
            continue
          }
          set(row.id, { state: "caiu" })
          input.log(`${row.id} disconnected during ${row.attempt}`)
          if (row.part_dir) await fs.appendFile(path.join(row.part_dir, "caiu"), `${alias}\n`).catch(() => undefined)
          continue
        }
        const driver = input.drivers()[row.kind.startsWith("ios") ? "ios" : "android"]
        if (!driver || !row.running) continue
        const health = await driver.health(device(row), JSON.parse(row.running)).catch(() => "mudo" as const)
        if (health === "ok") {
          if (row.mute_since !== null) set(row.id, { mute_since: null })
          continue
        }
        if (health === "mudo" && (row.mute_since === null || input.now() - row.mute_since < muteMs)) {
          if (row.mute_since === null) set(row.id, { mute_since: input.now() })
          continue
        }
        set(row.id, { state: "caiu" })
        input.log(`${row.id} fell (${health}) during ${row.attempt}`)
        if (row.part_dir) await fs.appendFile(path.join(row.part_dir, "caiu"), `${row.id}\n`).catch(() => undefined)
      }
    },
    /**
     * A free pair of console and adb ports for a local emulator, held for `device` from now on (its row's `running`):
     * one at a time, so emulators starting together never get the same pair.
     */
    consolePort: (id: string) => {
      const chosen = ports.chain.then(async () => {
        const taken = new Set(
          db
            .query<{ running: string }, []>("SELECT running FROM device WHERE running IS NOT NULL")
            .all()
            .flatMap((row) => (JSON.parse(row.running) as Running).console ?? []),
        )
        for (
          let port = input.emulatorPorts.start + (input.emulatorPorts.start % 2);
          port < input.emulatorPorts.end;
          port += 2
        )
          if (!taken.has(port) && (await free(port)) && (await free(port + 1))) {
            set(id, { running: JSON.stringify({ console: port }) })
            return port
          }
        throw new Error("sem porta livre para o emulador em portas.emulador")
      })
      ports.chain = chosen.catch(() => undefined)
      return chosen
    },
  }
}

export type DevicePool = ReturnType<typeof makeDevicePool>

/**
 * A launcher whose attempts get devices (`docs/bancada.md`, "Devices"): each part with devices has them prepared
 * while it builds, given back with its folder, and the folder held until they are back.
 */
export function withDevices(launcher: Launcher, pool: DevicePool, folder: (key: Placed) => string): Launcher {
  const ensure = (key: Placed) => {
    const dir = folder(key)
    if (pool.preparing(key)) return
    void Promise.all([
      Bun.file(path.join(dir, "devices.json")).exists(),
      Bun.file(path.join(dir, "devices.error")).exists(),
    ]).then(([ready, failed]) => {
      if (!ready && !failed) pool.prepare(key, dir)
    })
  }
  return {
    ...launcher,
    start: async (launch) => {
      await launcher.start(launch)
      launch.parts
        .filter((part) => part.devices > 0 || seat(part.spec) !== part.spec.platform)
        .forEach((part) => ensure({ job: launch.job, part: part.part, attempt: part.attempt, group: launch.group }))
    },
    // After a restart the attempt goes on: devices not ready yet are prepared again by this process.
    status: async (key) => {
      const status = await launcher.status(key)
      if (status.state === "compilando" || status.state === "rodando") ensure(key)
      return status
    },
    reap: async (live) => {
      await launcher.reap(live)
      pool.reap(live)
    },
    held: (key) => launcher.held(key) || pool.busy(key),
  }
}

/** Whether the part in `dir` has a plan, as its attempt's runner was told (`attempt.json` of its group). */
async function planned(dir: string) {
  const attempt = await Bun.file(path.join(path.dirname(path.dirname(dir)), "attempt.json"))
    .json()
    .catch(() => undefined)
  const parts: { part: string; plan?: unknown }[] = Array.isArray(attempt?.parts) ? attempt.parts : []
  return parts.some((part) => part.part === path.basename(dir) && part.plan !== undefined)
}

function free(port: number) {
  return new Promise<boolean>((resolve) => {
    const server = net.createServer()
    server.once("error", () => resolve(false))
    server.listen(port, "127.0.0.1", () => server.close(() => resolve(true)))
  })
}
