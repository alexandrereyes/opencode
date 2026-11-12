import { afterEach, describe, expect, test } from "bun:test"
import {
  busy,
  cpuTicks,
  darwinUsed,
  hostName,
  parseMeminfo,
  parseProcStat,
  parseVmStat,
  readCpu,
  readDisk,
  snapshot,
  type Probes,
} from "../src/host"
import { Host } from "../src/host/rpc"

// A Linux host's /proc/stat (two cores shown; the first line sums them), as the Linux BRS container reads it.
const procStat = `cpu  465660657 4177119 71964758 14029003208 1506912 0 18884232 0 181658782 0
cpu0 9701264 87023 1499266 292270900 31394 0 393421 0 3784557 0
cpu1 9701264 87023 1499266 292270900 31394 0 393421 0 3784557 0
intr 123 0 0
ctxt 99
`

const meminfo = `MemTotal:       396088704 kB
MemFree:        201234567 kB
MemAvailable:   373030836 kB
Buffers:          1234567 kB
Cached:         150000000 kB
`

const vmStat = `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                   157985.
Pages active:                                2010993.
Pages inactive:                              2088974.
Pages speculative:                             22315.
Pages throttled:                                   0.
Pages wired down:                             909301.
Pages purgeable:                              113981.
"Translation faults":                    62997717474.
File-backed pages:                           1617297.
Anonymous pages:                             2451273.
Pages stored in compressor:                  5982026.
Pages occupied by compressor:                3142270.
`

afterEach(() => {
  globalThis.opencodeCustomHostCpu = undefined
})

describe("custom.host", () => {
  test("publishes one read method", () => {
    expect(Host.Definition.id).toBe("custom.host")
    expect(Object.keys(Host.Definition.methods)).toEqual(["get"])
  })

  test("reads the whole machine's CPU from /proc/stat, with its cores", () => {
    const read = parseProcStat(procStat)
    // idle + iowait; user through steal, the guest columns already counted in user.
    expect(read?.ticks).toEqual({
      idle: 14029003208 + 1506912,
      total: 465660657 + 4177119 + 71964758 + 14029003208 + 1506912 + 0 + 18884232 + 0,
    })
    expect(read?.cores).toBe(2)
    expect(parseProcStat("intr 1 2\n")).toBeUndefined()
    expect(busy({ idle: 100, total: 200 }, { idle: 160, total: 300 })).toBe(40)
    expect(busy({ idle: 100, total: 200 }, { idle: 100, total: 200 })).toBeUndefined()
    expect(cpuTicks([{ model: "", speed: 0, times: { user: 3, nice: 0, sys: 1, idle: 6, irq: 0 } }])).toEqual({
      ticks: { idle: 6, total: 10 },
      cores: 1,
    })
    expect(cpuTicks([])).toBeUndefined()
  })

  test("counts the page cache as free memory on Linux", () => {
    expect(parseMeminfo(meminfo)).toEqual({ used: (396088704 - 373030836) * 1024, total: 396088704 * 1024 })
    // A kernel without MemAvailable: free, buffers and cache.
    expect(parseMeminfo(meminfo.replace(/^MemAvailable.*\n/m, ""))).toEqual({
      used: (396088704 - 201234567 - 1234567 - 150000000) * 1024,
      total: 396088704 * 1024,
    })
    expect(parseMeminfo("MemFree: 1 kB\n")).toBeUndefined()
  })

  test("reads macOS's memory as Activity Monitor's Memory Used", () => {
    const pages = parseVmStat(vmStat)
    expect(pages).toEqual({ pageSize: 16384, internal: 2451273, purgeable: 113981, wired: 909301, compressor: 3142270 })
    // App memory (anonymous less purgeable) + wired + compressed.
    expect(darwinUsed(pages!)).toBe((2451273 - 113981 + 909301 + 3142270) * 16384)
    expect(parseVmStat(vmStat.replace(/^Pages wired down.*\n/m, ""))).toBeUndefined()
  })

  test("samples the CPU once per process and shares close calls", async () => {
    let time = 1_000
    let calls = 0
    const ticks = [
      { idle: 0, total: 0 },
      { idle: 50, total: 100 },
      { idle: 80, total: 200 },
    ]
    const read = async () => ({ ticks: ticks[Math.min(calls++, ticks.length - 1)], cores: 8 })
    const waits: number[] = []
    const wait = async (ms: number) => void waits.push(ms)
    // First call: two readings 0.25 s apart.
    expect(await readCpu(read, () => time, wait)).toEqual({ percent: 50, cores: 8 })
    expect(waits).toEqual([250])
    // 0.2 s later: the same value, no new sample.
    time += 200
    expect(await readCpu(read, () => time, wait)).toEqual({ percent: 50, cores: 8 })
    // 2 s later: since the previous reading.
    time += 2_000
    calls = 2
    expect(await readCpu(read, () => time, wait)).toEqual({ percent: 70, cores: 8 })
    expect(waits).toEqual([250])
    expect(await readCpu(async () => undefined, () => time + 20_000, wait)).toBeUndefined()
  })

  test("leaves out only the part it cannot read", async () => {
    const probes: Probes = {
      name: async () => "Linux BRS",
      cpu: async () => ({ percent: 37, cores: 48 }),
      memory: async () => {
        throw new Error("no /proc/meminfo")
      },
      disk: async () => ({ free: 280e9, total: 1e12, path: "/workspace" }),
      platform: "linux",
      now: () => 42,
    }
    expect(await snapshot(undefined, probes)).toEqual({
      name: "Linux BRS",
      platform: "linux",
      scope: "machine",
      cpu: { percent: 37, cores: 48 },
      disk: { free: 280e9, total: 1e12, path: "/workspace" },
      at: 42,
    })
    // Only what was asked: the disk every minute, CPU and memory every two seconds.
    const asked = await snapshot(["disk"], probes)
    expect(asked.cpu).toBeUndefined()
    expect(asked.disk?.free).toBe(280e9)
  })

  test("names the host and measures the home folder's volume", async () => {
    expect(await hostName("  Linux BRS ")).toBe("Linux BRS")
    const disk = await readDisk()
    expect(disk && disk.total > 0 && disk.free >= 0 && disk.free <= disk.total).toBe(true)
  })
})
