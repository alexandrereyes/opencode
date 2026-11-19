import { Database } from "bun:sqlite"
import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { partSpec } from "../src/bancada/contract"
import type { AttemptKey, Launcher, Status } from "../src/bancada/daemon/executor"
import { runGit } from "../src/bancada/daemon/git"
import { liveness, makeProcessLauncher } from "../src/bancada/daemon/launcher/process"
import { awake } from "../src/bancada/daemon/runner"
import { migrate } from "../src/bancada/daemon/schema"
import { freeze } from "../src/bancada/daemon/snapshot"
import { makeWorkdirs } from "../src/bancada/daemon/workdir"
import { judge } from "../src/bancada/results"
import { initGit } from "../../core/test/fixture/git"

const example = path.join(import.meta.dir, "fixture/bancada-exemplo")
const folders: string[] = []
const groups: number[] = []
afterEach(async () => {
  // A test that failed may leave a command running in its own session.
  groups.splice(0).forEach((pid) => {
    try {
      process.kill(-pid, "SIGKILL")
    } catch {
      // Already gone.
    }
  })
  await Promise.all(folders.splice(0).map((folder) => fs.rm(folder, { recursive: true, force: true })))
})

/** The example project as a repository, a machine folder, and a launcher with short times. */
async function setup(options: { readonly runMs?: number; readonly runner?: string } = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-runner-"))
  folders.push(root)
  const repository = path.join(root, "projeto")
  await fs.cp(example, repository, { recursive: true })
  await initGit(repository)
  await runGit(["add", "-A"], { cwd: repository })
  await runGit(["commit", "-q", "-m", "exemplo"], { cwd: repository })
  const db = new Database(":memory:")
  migrate(db)
  let n = 0
  const random = () => `id-${++n}`
  const state = path.join(root, "state")
  const workdirs = makeWorkdirs({ db, root: path.join(state, "work"), now: Date.now, random, git: runGit })
  const launcher = makeProcessLauncher({
    state,
    workdirs,
    git: runGit,
    now: Date.now,
    random,
    deadlines: { prepareMs: 30_000, buildMs: 30_000, runMs: options.runMs ?? 60_000 },
    timing: { pollMs: 50, heartbeatMs: 200, killGraceMs: 500 },
    ...(options.runner ? { runner: options.runner } : {}),
  })
  return { root, repository, state, launcher }
}

async function launch(
  context: Awaited<ReturnType<typeof setup>>,
  input: { job: string; args: string[]; snapshot?: boolean; attempt?: number },
) {
  const frozen = await freeze({
    git: runGit,
    directory: context.repository,
    job: input.job,
    snapshot: input.snapshot === true,
  })
  if (!frozen.ok) throw new Error(frozen.problems.join("\n"))
  const key: AttemptKey = { job: input.job, part: "simples", attempt: input.attempt ?? 1 }
  await context.launcher.start({
    ...key,
    spec: partSpec(frozen.frozen.contract.tests.simples!, input.args),
    code: { project: frozen.frozen.project, commit: frozen.frozen.commit, remotes: [], inRemote: false },
    devices: 0,
    repository: context.repository,
  })
  return { key, dir: path.join(context.state, "attempts", input.job, `simples-${key.attempt}`) }
}

async function until(launcher: Launcher, key: AttemptKey, done: (status: Status) => boolean, ms = 15_000) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    const status = await launcher.status(key)
    if (done(status)) return status
    await Bun.sleep(50)
  }
  throw new Error(`no such status within ${ms} ms: ${JSON.stringify(await launcher.status(key))}`)
}
const ended = (status: Status) => status.state === "done" || status.state === "gone"
/** The process groups of the commands an attempt started, from its events. */
async function commands(dir: string) {
  const events = await Bun.file(path.join(dir, "events.jsonl")).text()
  const pids = events
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as { type: string; pid?: number })
    .flatMap((event) => (event.type === "command.start" && event.pid ? [event.pid] : []))
  groups.push(...pids)
  return pids
}
const groupAlive = (pid: number) => {
  try {
    process.kill(-pid, 0)
    return true
  } catch {
    return false
  }
}

describe("detached execution", () => {
  test("awake time never counts a sleep beyond the clamp", () => {
    expect([
      awake(0, 1_000, 1_200, 15_000),
      awake(500, 1_000, 3_600_000, 15_000),
      awake(500, 2_000, 1_000, 15_000),
    ]).toEqual([200, 15_500, 500])
  })

  test("the runner imports nothing but node: and Bun, so its copy runs from the attempt's folder alone", async () => {
    const source = await Bun.file(path.join(import.meta.dir, "../src/bancada/daemon/runner.ts")).text()
    const imports = [...source.matchAll(/^import .* from "([^"]+)"/gm)].map((match) => match[1])
    expect(imports.every((name) => name!.startsWith("node:") || name === "bun")).toBe(true)
  })

  // Starts the runner and the example's bash scripts as real processes.
  test("an attempt builds and runs the commit's contract from its own folder, once even when started twice", async () => {
    const context = await setup()
    await Bun.write(path.join(context.repository, "novo.txt"), "só no snapshot\n")
    const frozen = await freeze({ git: runGit, directory: context.repository, job: "j-aaaaaaaa", snapshot: true })
    if (!frozen.ok) throw new Error(frozen.problems.join("\n"))
    const key: AttemptKey = { job: "j-aaaaaaaa", part: "simples", attempt: 1 }
    const input = {
      ...key,
      spec: partSpec(frozen.frozen.contract.tests.simples!, ["--cenarios", "2", "--dorme", "1", "--marca", "novo.txt"]),
      code: { project: frozen.frozen.project, commit: frozen.frozen.commit, remotes: [], inRemote: false },
      devices: 0,
      repository: context.repository,
    }
    await Promise.all([context.launcher.start(input), context.launcher.start(input)])
    expect((await until(context.launcher, key, (status) => status.state === "rodando")).state).toBe("rodando")
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending)).toMatchObject({ verdict: "aprovado", planned: ["c1", "c2"], lost: [] })
    const dir = path.join(context.state, "attempts", "j-aaaaaaaa", "simples-1")
    const events = (await Bun.file(path.join(dir, "events.jsonl")).text())
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line))
    expect(events.filter((event) => event.type === "checkout")).toHaveLength(1)
    expect(await fs.readdir(dir)).toEqual(
      expect.arrayContaining(["attempt.json", "runner.json", "runner.ts", "build.log"]),
    )
    expect(await Bun.file(path.join(dir, "parts/simples/out/marca")).text()).toBe("só no snapshot\n")
    expect(await Bun.file(path.join(dir, "build.log")).text()).toContain("compilado")
    await commands(dir)
  }, 20_000)

  // A run that sleeps 30 s stopped by a 1 s deadline.
  test("a deadline of awake time ends the run and everything in its group", async () => {
    const context = await setup({ runMs: 1_000 })
    const { key, dir } = await launch(context, { job: "j-bbbbbbbb", args: ["--dorme", "30"] })
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(status.ending).toMatchObject({ stage: "run", cause: "prazo" })
    expect(judge(status.ending)).toMatchObject({
      verdict: "infraestrutura",
      reason: "prazo estourado",
      lost: ["c1", "c2"],
    })
    expect((await commands(dir)).map(groupAlive)).toEqual([false, false, false, false])
  }, 20_000)

  test("cancel ends the run and everything it started", async () => {
    const context = await setup()
    const { key, dir } = await launch(context, { job: "j-cccccccc", args: ["--dorme", "30"] })
    await until(context.launcher, key, (status) => status.state === "rodando")
    await context.launcher.cancel(key)
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending)).toMatchObject({ verdict: "cancelado" })
    expect((await commands(dir)).every((pid) => !groupAlive(pid))).toBe(true)
  }, 20_000)

  test("a killed runner is an execution that died, and starting it again never runs it twice", async () => {
    const context = await setup()
    const { key, dir } = await launch(context, { job: "j-dddddddd", args: ["--dorme", "30"] })
    await until(context.launcher, key, (status) => status.state === "rodando")
    const runner = (await Bun.file(path.join(dir, "runner.json")).json()) as { pid: number; startedAt: string }
    expect(await liveness(runner.pid)).toEqual({ state: "alive", started: runner.startedAt })
    process.kill(runner.pid, "SIGKILL")
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending)).toMatchObject({ verdict: "infraestrutura", reason: "a execução morreu" })
    await context.launcher.start({
      ...key,
      spec: partSpec(
        {
          name: "simples",
          label: "Simples",
          needs: [],
          device: {},
          devices: { min: 0, max: 0 },
          run: ["scripts/run"],
          args: [],
          exclusive: [],
        },
        [],
      ),
      code: { project: "bancada-exemplo", commit: "x", remotes: [], inRemote: false },
      devices: 0,
    })
    await Bun.sleep(300)
    const events = await Bun.file(path.join(dir, "events.jsonl")).text()
    expect(events.match(/"type":"checkout"/g)).toHaveLength(1)
    await commands(dir)
  }, 20_000)

  // Bundles the release's plugin file as the release does (`bun build --target=bun --minify`), then runs an attempt.
  test("the release's single plugin file, copied into the attempt's folder, is the runner there", async () => {
    const out = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-release-"))
    folders.push(out)
    const built = await Bun.build({
      entrypoints: [path.join(import.meta.dir, "../../cli/script/custom-plugin.ts")],
      target: "bun",
      minify: true,
      outdir: path.join(out, "plugin"),
      naming: "index.js",
    })
    expect(built.logs.filter((log) => log.level === "error")).toEqual([])
    const context = await setup({ runner: path.join(out, "plugin", "index.js") })
    const { key, dir } = await launch(context, { job: "j-hhhhhhhh", args: [] })
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending).verdict).toBe("aprovado")
    expect(await fs.readdir(dir)).toContain("runner.js")
    expect(await Bun.file(path.join(dir, "runner.log")).text()).toBe("")
    await commands(dir)
    // Nothing the rest of the plugin loads keeps the runner alive once its parts ended.
    const runner = (await Bun.file(path.join(dir, "runner.json")).json()) as { pid: number }
    groups.push(runner.pid)
    const deadline = Date.now() + 5_000
    while (Date.now() < deadline && (await liveness(runner.pid)).state !== "dead") await Bun.sleep(50)
    expect(await liveness(runner.pid)).toEqual({ state: "dead" })
  }, 30_000)

  test("in a reused folder a build broken by a stale cache is built once more from clean", async () => {
    const context = await setup()
    const first = await launch(context, { job: "j-eeeeeeee", args: [] })
    await until(context.launcher, first.key, ended)
    await context.launcher.finish(first.key)
    const second = await launch(context, { job: "j-ffffffff", args: ["--falha-com-cache"] })
    const status = await until(context.launcher, second.key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending).verdict).toBe("aprovado")
    expect(await Bun.file(path.join(second.dir, "events.jsonl")).text()).toContain('"type":"build.clean"')
    // A build that fails in a fresh folder is a compile error at once.
    const fresh = await launch(context, { job: "j-gggggggg", args: ["--falha-build"] })
    const failed = await until(context.launcher, fresh.key, ended)
    if (failed.state !== "done") throw new Error(JSON.stringify(failed))
    expect(judge(failed.ending)).toMatchObject({ verdict: "compilacao" })
    expect(await Bun.file(path.join(fresh.dir, "events.jsonl")).text()).not.toContain("build.clean")
  }, 30_000)
})
