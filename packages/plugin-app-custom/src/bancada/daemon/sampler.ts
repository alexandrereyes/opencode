import type { Database } from "bun:sqlite"
import path from "node:path"
import type { BancadaProtocol } from "../protocol.js"
import { add, samples, type Cost } from "./budget.js"
import type { Running } from "./devices/pool.js"

/**
 * What devices and builds really take on this machine (`docs/bancada.md`, "Budget"): every 10 s, the memory and CPU of
 * each device in use (an emulator's process and those below it, a simulator's processes, a container's `docker stats`)
 * and of each build (its runner's processes while its attempt builds). When one ends, its peak memory and average CPU
 * go to `cost_sample` (the last 20 per subject); the admission takes their p90 from 3 samples on (`executor.ts`).
 */

/** One process as `ps` lists it. */
export type Process = {
  readonly pid: number
  readonly ppid: number
  readonly memMb: number
  readonly cpuMilli: number
  readonly command: string
}

/** The same `ps` on macOS and Linux: resident memory in KiB, CPU in percent of one core, the command line. */
export const psCommand = ["ps", "-A", "-o", "pid=,ppid=,rss=,pcpu=,args="]

export function parsePs(text: string): Process[] {
  return text.split("\n").flatMap((line) => {
    const found = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d.,]+)\s+(.*)$/.exec(line)
    if (!found) return []
    return [
      {
        pid: Number(found[1]),
        ppid: Number(found[2]),
        memMb: Number(found[3]) / 1024,
        cpuMilli: Number(found[4]!.replace(",", ".")) * 10,
        command: found[5]!,
      },
    ]
  })
}

/** `docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'`: `3.49GiB / 8GiB` and `284.74%`. */
export function parseDockerStats(text: string) {
  const units: Record<string, number> = {
    B: 1 / 1024 / 1024,
    KiB: 1 / 1024,
    kB: 1 / 1024,
    MiB: 1,
    MB: 1,
    GiB: 1024,
    GB: 1024,
  }
  return new Map(
    text.split("\n").flatMap((line): [string, Cost][] => {
      const [name, memory, cpu] = line.split("\t")
      const used = /^([\d.]+)\s*([A-Za-z]+)/.exec(memory?.trim() ?? "")
      const percent = /^([\d.]+)%/.exec(cpu?.trim() ?? "")
      if (!name || !used || !percent || units[used[2]!] === undefined) return []
      return [[name, { memMb: Number(used[1]) * units[used[2]!]!, cpuMilli: Number(percent[1]) * 10 }]]
    }),
  )
}

/** The processes `roots` and every one below them, summed once each (a root may be below another). */
export function tree(processes: ReadonlyArray<Process>, roots: ReadonlyArray<number>): Cost | undefined {
  const children = Map.groupBy(processes, (item) => item.ppid)
  const byPid = new Map(processes.map((item) => [item.pid, item]))
  const found = new Map<number, Process>()
  const walk = (pid: number) => {
    const item = byPid.get(pid)
    if (!item || found.has(pid)) return
    found.set(pid, item)
    children.get(pid)?.forEach((child) => walk(child.pid))
  }
  roots.forEach(walk)
  if (found.size === 0) return undefined
  return add(...[...found.values()].map((item) => ({ memMb: item.memMb, cpuMilli: item.cpuMilli })))
}

export function makeSampler(input: {
  readonly db: Database
  readonly now: () => number
  /** Where the attempts' folders are (`attempts/<job>/<group>/runner.json`). */
  readonly state: string
  readonly run: (argv: ReadonlyArray<string>) => Promise<{ readonly code: number; readonly stdout: string }>
  readonly log: (line: string) => void
}) {
  const db = input.db
  const devices = db.query<{ id: string; kind: string; profile: string; running: string; attempt: string }, []>(
    "SELECT id, kind, profile, running, attempt FROM device WHERE state = 'em_uso' AND running IS NOT NULL AND attempt IS NOT NULL AND kind NOT LIKE '%-fisico'",
  )
  const builds = db.query<{ job_id: string; group_id: string; code: string }, []>(
    "SELECT DISTINCT job_id, group_id, code FROM attempt WHERE state = 'compilando' AND group_id IS NOT NULL",
  )
  /** What is being measured: its subject, its peak memory, the sum of its CPU readings and how many. */
  const open = new Map<string, { subject: string; memMb: number; cpuMilli: number; readings: number }>()
  const busy = { now: false }

  const read = async () => {
    const using = devices.all()
    const building = builds.all()
    const containers = using.flatMap((row) => (JSON.parse(row.running) as Running).container ?? [])
    const [ps, stats] = await Promise.all([
      using.length > containers.length || building.length > 0 ? input.run(psCommand) : undefined,
      containers.length > 0
        ? input.run([
            "docker",
            "stats",
            "--no-stream",
            "--format",
            "{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}",
            ...containers,
          ])
        : undefined,
    ])
    const processes = ps?.code === 0 ? parsePs(ps.stdout) : []
    const stat = stats?.code === 0 ? parseDockerStats(stats.stdout) : new Map<string, Cost>()
    const device = using.flatMap((row) => {
      const running: Running = JSON.parse(row.running)
      const cost = running.container
        ? stat.get(running.container)
        : running.pid
          ? tree(processes, [running.pid])
          : running.udid
            ? tree(
                processes,
                processes.filter((item) => item.command.includes(`/Devices/${running.udid}`)).map((item) => item.pid),
              )
            : undefined
      return cost ? [[`device:${row.id}:${row.attempt}`, { subject: `${row.kind}:${row.profile}`, cost }] as const] : []
    })
    const build = await Promise.all(
      building.map(async (row) => {
        const runner = await Bun.file(path.join(input.state, "attempts", row.job_id, row.group_id, "runner.json"))
          .json()
          .catch(() => undefined)
        const cost = Number.isInteger(runner?.pid) ? tree(processes, [runner.pid as number]) : undefined
        const project = (JSON.parse(row.code) as BancadaProtocol.Code).project
        return cost ? [[`build:${row.job_id}/${row.group_id}`, { subject: `build:${project}`, cost }] as const] : []
      }),
    )
    return new Map<string, { readonly subject: string; readonly cost: Cost }>([...device, ...build.flat()])
  }

  /** One reading; what ended since the last one becomes a sample (two readings at least). */
  const take = async () => {
    if (busy.now) return
    busy.now = true
    const now = await read().finally(() => {
      busy.now = false
    })
    for (const [key, item] of now) {
      const known = open.get(key) ?? { subject: item.subject, memMb: 0, cpuMilli: 0, readings: 0 }
      open.set(key, {
        subject: item.subject,
        memMb: Math.max(known.memMb, item.cost.memMb),
        cpuMilli: known.cpuMilli + item.cost.cpuMilli,
        readings: known.readings + 1,
      })
    }
    for (const [key, item] of open) {
      if (now.has(key)) continue
      open.delete(key)
      if (item.readings < 2) continue
      const cost = { memMb: Math.round(item.memMb), cpuMilli: Math.round(item.cpuMilli / item.readings) }
      db.transaction(() => {
        db.run("INSERT INTO cost_sample (subject, mem_mb, cpu_milli, at) VALUES (?, ?, ?, ?)", [
          item.subject,
          cost.memMb,
          cost.cpuMilli,
          input.now(),
        ])
        db.run(
          "DELETE FROM cost_sample WHERE subject = ? AND rowid NOT IN (SELECT rowid FROM cost_sample WHERE subject = ? ORDER BY at DESC, rowid DESC LIMIT ?)",
          [item.subject, item.subject, samples.kept],
        )
      })()
      input.log(`measured ${item.subject}: ${cost.memMb} MB, ${cost.cpuMilli} milli-CPU (${item.readings} readings)`)
    }
  }

  return { take }
}

export type Sampler = ReturnType<typeof makeSampler>
