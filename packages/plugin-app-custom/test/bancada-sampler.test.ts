import { Database } from "bun:sqlite"
import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { makeSampler, parseDockerStats, parsePs, tree } from "../src/bancada/daemon/sampler"
import { migrate } from "../src/bancada/daemon/schema"

const folders: string[] = []
afterEach(() => Promise.all(folders.splice(0).map((folder) => fs.rm(folder, { recursive: true, force: true }))))

/** `ps -A -o pid=,ppid=,rss=,pcpu=,args=` as the Mac prints it (a comma in a Portuguese locale). */
const ps = (emulatorKb: number, qemuCpu: string, buildKb: number) =>
  [
    "    1     0   12000   0.0 /sbin/launchd",
    `  100     1  ${10_240}   0.5 /sdk/emulator/emulator -avd bancada-a370-ga-arm64-enxuto-1 -ports 5584,5585`,
    `  101   100 ${emulatorKb} ${qemuCpu} /sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd bancada-a370`,
    "  300     1   51200   3,0 /Library/Developer/CoreSimulator/launchd_sim /Users/u/Library/Developer/CoreSimulator/Devices/UDID-1/data/var/run/launchd_bootstrap.plist",
    "  301   300  102400  10,0 /RuntimeRoot/usr/libexec/backboardd",
    "  200     1   40960   1.0 bun runner.js",
    `  201   200 ${buildKb}  400.0 dotnet build src/Abacato.sln`,
    "  999     1 9999999  99.0 /Applications/Outro.app/Contents/MacOS/Outro",
  ].join("\n")

describe("measured costs", () => {
  test("ps on macOS and Linux, docker stats, and a process with those below it", () => {
    const processes = parsePs(ps(4_194_304, "120,5", 2_097_152))
    expect(processes[2]).toEqual({
      pid: 101,
      ppid: 100,
      memMb: 4_096,
      cpuMilli: 1_205,
      command: "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd bancada-a370",
    })
    expect(tree(processes, [100])).toEqual({ memMb: 4_106, cpuMilli: 1_210 })
    expect(tree(processes, [300])).toEqual({ memMb: 150, cpuMilli: 130 })
    // A simulator's processes that name its device are below its launchd_sim: counted once.
    expect(tree(processes, [300, 301])).toEqual({ memMb: 150, cpuMilli: 130 })
    expect(tree(processes, [4242])).toBeUndefined()
    expect(
      parseDockerStats(
        "bancada-emu-2\t3.493GiB / 8GiB\t15.12%\nbancada-emu-1\t512MiB / 8GiB\t284.74%\nquebrado\t--\t--\n",
      ),
    ).toEqual(
      new Map([
        ["bancada-emu-2", { memMb: 3.493 * 1024, cpuMilli: 151.2 }],
        ["bancada-emu-1", { memMb: 512, cpuMilli: 2_847.4 }],
      ]),
    )
  })

  test("each device in use and each build: its peak memory and average CPU become a sample when it ends", async () => {
    const state = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-sampler-"))
    folders.push(state)
    const db = new Database(":memory:")
    migrate(db)
    const device = (id: string, kind: string, running: Record<string, unknown>) =>
      db.run(
        "INSERT INTO device (id, kind, profile, choice, spec, state, running, attempt, falls, last_used_at) VALUES (?, ?, 'enxuto', 'c', '{}', 'em_uso', ?, 'j-1/android/1', 0, 0)",
        [id, kind, JSON.stringify(running)],
      )
    device("bancada-a370-ga-arm64-enxuto-1", "android-emulador", { serial: "emulator-5584", pid: 100 })
    device("bancada-iphone-17-pro-1", "ios-simulador", { udid: "UDID-1" })
    device("bancada-emu-1", "android-docker", { container: "bancada-emu-1" })
    db.run(
      "INSERT INTO attempt (job_id, part, n, origin, code, spec, devices, state, lease_id, group_id, accepted_at) VALUES ('j-1', 'android', 1, '{}', ?, '{}', 1, 'compilando', 'l1', 'g', 0)",
      [JSON.stringify({ project: "abacato-v3", commit: "c", remotes: [], inRemote: false })],
    )
    await Bun.write(path.join(state, "attempts", "j-1", "g", "runner.json"), JSON.stringify({ pid: 200 }))
    const readings = [
      ps(4_194_304, "100.0", 2_097_152),
      ps(6_291_456, "300.0", 6_291_456),
      ps(5_242_880, "50.0", 1_048_576),
    ]
    const asked: string[] = []
    const lines: string[] = []
    const sampler = makeSampler({
      db,
      now: () => 1_000,
      state,
      run: async (argv) => {
        asked.push(argv[0]!)
        return argv[0] === "docker"
          ? { code: 0, stdout: "bancada-emu-1\t4GiB / 8GiB\t270%\n" }
          : { code: 0, stdout: readings.shift() ?? "" }
      },
      log: (line) => lines.push(line),
    })
    await sampler.take()
    await sampler.take()
    // The build ends; the run goes on.
    db.run("UPDATE attempt SET state = 'rodando'")
    await sampler.take()
    // The attempt ends: its devices are given back.
    db.run("UPDATE device SET state = 'devolvendo'")
    await sampler.take()
    expect(
      db.query("SELECT subject, mem_mb AS memMb, cpu_milli AS cpuMilli FROM cost_sample ORDER BY subject").all(),
    ).toEqual([
      { subject: "android-docker:enxuto", memMb: 4_096, cpuMilli: 2_700 },
      // The peak of the emulator's processes (6 GiB + 10 MiB), the average of its CPU (100, 300 and 50 %, plus 0.5 %).
      { subject: "android-emulador:enxuto", memMb: 6_154, cpuMilli: 1_505 },
      // Two readings while it built: the runner and the build below it.
      { subject: "build:abacato-v3", memMb: 6_184, cpuMilli: 4_010 },
      { subject: "ios-simulador:enxuto", memMb: 150, cpuMilli: 130 },
    ])
    expect(lines).toContain("measured build:abacato-v3: 6184 MB, 4010 milli-CPU (2 readings)")
    // Nothing in use: nothing is asked.
    asked.length = 0
    await sampler.take()
    expect(asked).toEqual([])
  })
})
