// Real devices on this Mac, by hand (P12): `bun bancada-devices-real.ts <scratch> <example>`. Discovers the machine,
// makes one emulator and one simulator `bancada-test-…` ready through the device pool, runs the example's `run` on
// them ("chegou pronto"), boots the emulator again from its snapshot (timed), kills it in the middle (a fall), gives
// everything back and deletes it. Prints what it measured; exits 1 when something did not hold.
import { Database } from "bun:sqlite"
import fs from "node:fs/promises"
import path from "node:path"
import { discover, systemProbe } from "../../src/bancada/daemon/capabilities"
import { makeDevicePool } from "../../src/bancada/daemon/devices/pool"
import { systemShell } from "../../src/bancada/daemon/devices/shell"
import { deviceDrivers } from "../../src/bancada/daemon/main"
import { migrate } from "../../src/bancada/daemon/schema"
import { iosSlim } from "../../src/bancada/catalog/slim"
import { parseMachineConfig } from "../../src/bancada/machine-config"
import { makeIosLifecycle } from "../../src/resources/adapters/ios-lifecycle"

const [scratch, example] = process.argv.slice(2)
if (!scratch || !example) throw new Error("usage: bancada-devices-real.ts <scratch> <example>")
const state = path.join(scratch, "state")
await fs.mkdir(path.join(state, "devices"), { recursive: true })
await Bun.write(path.join(state, "simslim-profile.json"), JSON.stringify(iosSlim))
const parsed = parseMachineConfig(`versao = 1\nprefixo = "bancada-test-"\n[execucao]\nmodo = "processo"\n`, {
  memMb: 64_000,
  cores: 16,
  platform: process.platform,
})
if (!parsed.ok) throw new Error(parsed.problems.join("\n"))
const config = parsed.config
const found = await discover(systemProbe(), config)
console.log("android tools:", JSON.stringify(found.android), "simslim:", found.simslim)
const db = new Database(":memory:")
migrate(db)
const log = (line: string) => console.log(`  ${new Date().toISOString().slice(11, 19)} ${line}`)
const pool = makeDevicePool({
  db,
  now: () => Date.now(),
  drivers: () => deviceDrivers(found, config, state, () => "Mac (teste)", pool),
  emulatorPorts: config.ports.emulator,
  simslim: () => found.simslim !== undefined,
  log,
})
const failures: string[] = []

const attempt = async (n: number, platform: "android" | "ios") => {
  const spec = {
    part: platform,
    label: platform,
    platform,
    needs: [platform],
    device: platform === "ios" ? { ios: ">=26.0", model: "iPhone 17 Pro" } : { api: ">=36", slim: "aceita" },
    devices: { min: 1, max: 1 },
    exclusive: [],
    unsafe: false,
    build: false,
    args: [],
  }
  db.run(
    "INSERT INTO attempt (job_id, part, n, origin, code, spec, devices, state, lease_id, accepted_at) VALUES ('j-real', ?, ?, '{}', '{}', ?, 1, 'rodando', ?, 0)",
    [platform, n, JSON.stringify(spec), `l-${platform}-${n}`],
  )
  db.run("INSERT INTO lease_device (lease_id, device_id, port_start, port_end) VALUES (?, NULL, ?, ?)", [
    `l-${platform}-${n}`,
    48_000 + n * 20,
    48_019 + n * 20,
  ])
  const dir = path.join(scratch, "attempts", `${platform}-${n}`)
  await fs.mkdir(path.join(dir, "out"), { recursive: true })
  return { key: { job: "j-real", part: platform, attempt: n, group: "g" }, dir }
}

/** Prepares, then runs the example's `run` on the devices; the summary's verdict per scenario. */
const round = async (n: number, platform: "android" | "ios") => {
  const one = await attempt(n, platform)
  const started = Date.now()
  pool.prepare(one.key, one.dir)
  await pool.settled()
  const ready = Math.round((Date.now() - started) / 1000)
  if (await Bun.file(path.join(one.dir, "devices.error")).exists()) {
    failures.push(`${platform} ${n}: ${await Bun.file(path.join(one.dir, "devices.error")).text()}`)
    return { one, ready }
  }
  console.log(`${platform} ${n}: ready in ${ready} s:`, await Bun.file(path.join(one.dir, "devices.json")).text())
  const run = Bun.spawnSync(["bash", path.join(example, "scripts/run"), "--cenarios", "0"], {
    cwd: example,
    env: {
      ...process.env,
      BANCADA_OUT: path.join(one.dir, "out"),
      BANCADA_DEVICES: path.join(one.dir, "devices.json"),
    },
  })
  const summary = (await Bun.file(path.join(one.dir, "out", "summary.json")).json()) as {
    cenarios: { id: string; resultado: string; mensagem?: string }[]
  }
  console.log(`${platform} ${n}: run exit ${run.exitCode}`)
  for (const file of await fs.readdir(path.join(one.dir, "out")))
    if (file.endsWith(".log") || file.endsWith(".txt"))
      console.log(`  ${file}: ${(await Bun.file(path.join(one.dir, "out", file)).text()).trim()}`)
  summary.cenarios.forEach((item) =>
    console.log(`  ${item.id}: ${item.resultado}${item.mensagem ? ` (${item.mensagem})` : ""}`),
  )
  summary.cenarios
    .filter((item) => item.resultado !== "passou")
    .forEach((item) => failures.push(`${platform} ${n}: ${item.id} ${item.mensagem ?? ""}`))
  return { one, ready }
}

const ios = process.argv.includes("--sem-ios") ? undefined : await round(1, "ios")
const android = process.argv.includes("--sem-android") ? undefined : await round(1, "android")
pool.reap([])
await pool.settled()

if (android) {
  // Again: from the snapshot, then the emulator killed in the middle.
  const again = await round(2, "android")
  console.log(`android 2: from the snapshot in ${again.ready} s`)
  const row = db.query<{ running: string | null }, []>("SELECT running FROM device WHERE state = 'em_uso'").get()
  const pid = row?.running ? (JSON.parse(row.running) as { pid: number }).pid : 0
  if (pid) process.kill(pid, "SIGKILL")
  await Bun.sleep(2_000)
  await pool.watch()
  const fell = await Bun.file(path.join(again.one.dir, "caiu"))
    .text()
    .catch(() => "")
  console.log(`android 2: fell after kill: ${fell.trim() || "(nothing)"}`)
  if (!fell.trim()) failures.push("the killed emulator did not fall")
  pool.reap([])
  await pool.settled()
}
if (ios) {
  const again = await round(2, "ios")
  console.log(`ios 2: ready again in ${again.ready} s (after erase)`)
  pool.reap([])
  await pool.settled()
}

// Delete what this run made, and say what is left with the prefix.
const shell = systemShell()
for (const device of db.query<{ id: string; kind: string }, []>("SELECT id, kind FROM device").all()) {
  if (device.kind === "ios-simulador") {
    const listed = await makeIosLifecycle(shell, {}).find(device.id)
    if (listed) await makeIosLifecycle(shell, {}).destroy(listed.udid, device.id)
  } else if (found.android) {
    await shell.run([found.android.avdmanager ?? "true", "delete", "avd", "-n", device.id], {
      env: { JAVA_HOME: found.android.javaHome ?? "", ANDROID_SDK_ROOT: found.android.sdk },
      timeoutMs: 60_000,
    })
  }
}
const avds = (await shell.run([found.android?.emulator ?? "true", "-list-avds"])).stdout
const sims = (await shell.run(["/usr/bin/xcrun", "simctl", "list", "devices"])).stdout
const left = [...avds.split("\n"), ...sims.split("\n")].filter((line) => line.includes("bancada-test-"))
console.log("left with bancada-test-:", left.length ? left.join("; ") : "nothing")
if (left.length) failures.push(`left behind: ${left.join("; ")}`)
console.log(failures.length ? `FAILED:\n${failures.join("\n")}` : "OK")
process.exit(failures.length ? 1 : 0)
