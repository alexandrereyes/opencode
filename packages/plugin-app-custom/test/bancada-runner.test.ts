import { Database } from "bun:sqlite"
import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { partSpec } from "../src/bancada/contract"
import type { AttemptKey, Launcher, Status } from "../src/bancada/daemon/executor"
import { runGit } from "../src/bancada/daemon/git"
import { liveness, makeProcessLauncher, orphan } from "../src/bancada/daemon/launcher/process"
import { awake, startOf } from "../src/bancada/daemon/runner"
import { migrate } from "../src/bancada/daemon/schema"
import { freeze } from "../src/bancada/daemon/snapshot"
import { makeWorkdirs } from "../src/bancada/daemon/workdir"
import { judge } from "../src/bancada/results"
import { initGit } from "../../core/test/fixture/git"

const example = path.join(import.meta.dir, "fixture/bancada-exemplo")
const runnerModule = path.join(import.meta.dir, "../src/bancada/daemon/runner.ts")
const folders: string[] = []
const groups: number[] = []
afterEach(async () => {
  // A test that failed may leave a runner or a command running in its own session.
  groups.splice(0).forEach((pid) => kill(pid))
  await Promise.all(folders.splice(0).map((folder) => fs.rm(folder, { recursive: true, force: true })))
})

/** The example project as a repository, a machine folder, and a launcher with short times. */
async function setup(options: { readonly runMs?: number; readonly runner?: string; readonly graceMs?: number } = {}) {
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
  /** A launcher of this machine; another one is the Bancada process after a restart (nothing in memory). */
  const launcher = (more: { readonly runner?: string; readonly now?: () => number } = {}) =>
    makeProcessLauncher({
      state,
      workdirs,
      git: runGit,
      now: more.now ?? Date.now,
      random,
      deadlines: { prepareMs: 30_000, buildMs: 30_000, runMs: options.runMs ?? 60_000 },
      timing: { pollMs: 50, heartbeatMs: 200, killGraceMs: 500 },
      ...(options.graceMs ? { startGraceMs: options.graceMs } : {}),
      ...((more.runner ?? options.runner) ? { runner: more.runner ?? options.runner } : {}),
    })
  return { root, repository, state, workdirs, launcher: launcher(), restarted: launcher }
}
type Context = Awaited<ReturnType<typeof setup>>

/** Freezes the repository's HEAD (or working tree) for `job` and what starting its attempt of `part` takes. */
async function prepare(context: Context, input: { job: string; args?: string[]; part?: string; snapshot?: boolean }) {
  const frozen = await freeze({
    git: runGit,
    directory: context.repository,
    job: input.job,
    snapshot: input.snapshot === true,
  })
  if (!frozen.ok) throw new Error(frozen.problems.join("\n"))
  const part = input.part ?? "simples"
  const key: AttemptKey = { job: input.job, part, attempt: 1 }
  return {
    key,
    dir: path.join(context.state, "attempts", input.job, `${part}-1`),
    launch: {
      ...key,
      spec: partSpec(frozen.frozen.contract.tests[part]!, input.args ?? []),
      code: { project: frozen.frozen.project, commit: frozen.frozen.commit, remotes: [], inRemote: false },
      devices: 0,
      repository: context.repository,
    },
  }
}
async function launch(context: Context, input: { job: string; args?: string[]; part?: string; snapshot?: boolean }) {
  const prepared = await prepare(context, input)
  await context.launcher.start(prepared.launch)
  return prepared
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
async function waitFor(condition: () => Promise<boolean> | boolean, ms = 15_000) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (await condition()) return
    await Bun.sleep(50)
  }
  throw new Error(`condition not met within ${ms} ms`)
}
const ended = (status: Status) => status.state === "done" || status.state === "gone"
const events = async (dir: string) =>
  (
    await Bun.file(path.join(dir, "events.jsonl"))
      .text()
      .catch(() => "")
  )
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as { type: string; pid?: number; startedAt?: string })
/** The process groups of the commands an attempt started (and its runner), from its folder. */
async function commands(dir: string) {
  const pids = (await events(dir)).flatMap((event) => (event.type === "command.start" && event.pid ? [event.pid] : []))
  const runner = (await Bun.file(path.join(dir, "runner.json"))
    .json()
    .catch(() => undefined)) as { pid?: number } | undefined
  groups.push(...pids, ...(runner?.pid ? [runner.pid] : []))
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
function kill(pid: number) {
  try {
    process.kill(-pid, "SIGKILL")
  } catch {
    // Already gone.
  }
}
/** Reaps every round, as the executor does, until no folder is held. */
async function reaped(context: Context) {
  await waitFor(async () => {
    await context.launcher.reap([])
    return context.workdirs.held().length === 0
  })
}
async function scratch() {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-scratch-"))
  folders.push(folder)
  return folder
}
/** A runner that arrives `ms` late (a Mac at its limit), then runs the real one and leaves a mark when it is done. */
async function slowRunner(root: string, ms: number) {
  const file = path.join(root, `slow-${ms}.ts`)
  await Bun.write(
    file,
    `const dir = process.argv[process.argv.indexOf("--opencode-bancada-run") + 1]\n` +
      `await Bun.sleep(${ms})\n` +
      `await import(${JSON.stringify(runnerModule)})\n` +
      `await Bun.write(dir + "/left", "")\n`,
  )
  return file
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
    const source = await Bun.file(runnerModule).text()
    const imports = [...source.matchAll(/^import .* from "([^"]+)"/gm)].map((match) => match[1])
    expect(imports.every((name) => name!.startsWith("node:") || name === "bun")).toBe(true)
  })

  // Starts the runner and the example's bash scripts as real processes.
  test("an attempt builds and runs the commit's contract from its own folder, once even when started twice", async () => {
    const context = await setup()
    await Bun.write(path.join(context.repository, "novo.txt"), "só no snapshot\n")
    const { key, dir, launch } = await prepare(context, {
      job: "j-aaaaaaaa",
      args: ["--cenarios", "2", "--dorme", "1", "--marca", "novo.txt"],
      snapshot: true,
    })
    await context.launcher.start(launch)
    await context.launcher.start(launch)
    expect((await until(context.launcher, key, (status) => status.state === "rodando")).state).toBe("rodando")
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending)).toMatchObject({ verdict: "aprovado", planned: ["c1", "c2"], lost: [] })
    expect((await events(dir)).filter((event) => event.type === "checkout")).toHaveLength(1)
    expect(await fs.readdir(dir)).toEqual(
      expect.arrayContaining(["attempt.json", "runner.json", "runner.ts", "build.log"]),
    )
    expect(await Bun.file(path.join(dir, "parts/simples/out/marca")).text()).toBe("só no snapshot\n")
    expect(await Bun.file(path.join(dir, "build.log")).text()).toContain("compilado")
    // Every command recorded its start time and its end; nothing of their groups is left.
    const all = await events(dir)
    const started = all.filter((event) => event.type === "command.start")
    expect(started.every((event) => typeof event.startedAt === "string")).toBe(true)
    expect(all.filter((event) => event.type === "command.end").map((event) => event.pid)).toEqual(
      started.map((event) => event.pid),
    )
    expect((await commands(dir)).some(groupAlive)).toBe(false)
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

  // Kills the runner while the example's run sleeps 30 s.
  test("a killed runner is an execution that died; its run is ended, with proof, before the folder goes back", async () => {
    const context = await setup()
    const { key, dir, launch } = await prepare(context, { job: "j-dddddddd", args: ["--dorme", "30"] })
    await context.launcher.start(launch)
    await until(context.launcher, key, (status) => status.state === "rodando")
    const runner = (await Bun.file(path.join(dir, "runner.json")).json()) as { pid: number; startedAt: string }
    expect(await liveness(runner.pid)).toEqual({ state: "alive", started: runner.startedAt })
    process.kill(runner.pid, "SIGKILL")
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending)).toMatchObject({ verdict: "infraestrutura", reason: "a execução morreu" })
    // Started again, it never runs twice.
    await context.launcher.start(launch)
    expect((await events(dir)).filter((event) => event.type === "checkout")).toHaveLength(1)
    // The run outlived its runner and holds the folder until the reaping ends it.
    const run = (await commands(dir)).at(-1)!
    expect(groupAlive(run)).toBe(true)
    await context.launcher.reap([key])
    expect(context.workdirs.held()).toHaveLength(1)
    await reaped(context)
    expect(groupAlive(run)).toBe(false)
  }, 20_000)

  test("orphans: a leader with another start time, or without a recorded one, is never touched", async () => {
    const child = Bun.spawn(["sleep", "30"], { detached: true })
    groups.push(child.pid)
    const started = await startOf(child.pid)
    expect(await orphan(child.pid, "outra hora", 200)).toBe(true)
    expect(await orphan(child.pid, undefined, 200)).toBe(false)
    expect(groupAlive(child.pid)).toBe(true)
    expect(await orphan(child.pid, started, 200)).toBe(true)
    expect(groupAlive(child.pid)).toBe(false)
  })

  test("a start that failed after taking a folder gives it back once the attempt no longer lives", async () => {
    const context = await setup({ runner: "/nonexistent/runner.ts" })
    const { key, launch } = await prepare(context, { job: "j-eeeeeeee" })
    expect(
      await context.launcher.start(launch).then(
        () => "started",
        (error: Error) => error.message,
      ),
    ).toContain("ENOENT")
    expect(context.workdirs.held().map((held) => held.owner)).toEqual(["j-eeeeeeee/simples/1"])
    await context.launcher.reap([key])
    expect(context.workdirs.held()).toHaveLength(1)
    await reaped(context)
  })

  // A runner that arrives 1.5 s late against a 300 ms grace.
  test("a runner that arrives after its start was revoked leaves without running anything", async () => {
    const context = await setup({ graceMs: 300, runner: await slowRunner(await scratch(), 1_500) })
    const { key, dir } = await launch(context, { job: "j-ffffffff" })
    expect(await until(context.launcher, key, ended)).toEqual({ state: "gone", reason: "a execução não começou" })
    await waitFor(() => Bun.file(path.join(dir, "left")).exists())
    expect(await Bun.file(path.join(dir, "runner.json")).json()).toMatchObject({ revoked: true })
    expect(await events(dir)).toEqual([])
  }, 20_000)

  // The process dies right after its start (the runner 1.5 s late) and a new one comes back five minutes later.
  test("a process back minutes after a start whose runner had not arrived runs the attempt once and never loses it", async () => {
    const context = await setup({ runner: await slowRunner(await scratch(), 1_500) })
    const { key, dir, launch } = await prepare(context, { job: "j-gggggggg" })
    await context.launcher.start(launch)
    const later = context.restarted({ runner: runnerModule, now: () => Date.now() + 5 * 60_000 })
    expect(await later.status(key)).toEqual({ state: "unstarted" })
    await later.start(launch)
    const status = await until(later, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending).verdict).toBe("aprovado")
    await waitFor(() => Bun.file(path.join(dir, "left")).exists())
    expect((await events(dir)).filter((event) => event.type === "checkout")).toHaveLength(1)
    await commands(dir)
  }, 20_000)

  test("an attempt.json cut in half is written again", async () => {
    const context = await setup()
    const { key, dir, launch } = await prepare(context, { job: "j-hhhhhhhh" })
    await fs.mkdir(dir, { recursive: true })
    await Bun.write(path.join(dir, "attempt.json"), '{ "format": 1, "job": "j-hh')
    await context.launcher.start(launch)
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending).verdict).toBe("aprovado")
    await commands(dir)
  }, 20_000)

  test("a command that cannot start is that part's result, and the runner lives to write it", async () => {
    const context = await setup()
    await Bun.write(path.join(context.repository, "scripts/sem-x.txt"), "echo nunca\n")
    await fs.symlink("sem-x.txt", path.join(context.repository, "scripts/quebrado"))
    await Bun.write(
      path.join(context.repository, ".bancada.toml"),
      (await Bun.file(path.join(context.repository, ".bancada.toml")).text()) +
        `\n[teste.quebrado]\naparelhos = { min = 0, max = 0 }\nrun = "scripts/quebrado"\n`,
    )
    await runGit(["add", "-A"], { cwd: context.repository })
    await runGit(["commit", "-q", "-m", "quebrado"], { cwd: context.repository })
    const { key, dir } = await launch(context, { job: "j-kkkkkkkk", part: "quebrado" })
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(status.ending).toMatchObject({ stage: "run", exit: 126 })
    expect(judge(status.ending)).toMatchObject({
      verdict: "infraestrutura",
      reason: expect.stringContaining("o comando não partiu"),
    })
    expect(await Bun.file(path.join(dir, "runner.log")).text()).toBe("")
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
    const { key, dir } = await launch(context, { job: "j-mmmmmmmm" })
    const status = await until(context.launcher, key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending).verdict).toBe("aprovado")
    expect(await fs.readdir(dir)).toContain("runner.js")
    expect(await Bun.file(path.join(dir, "runner.log")).text()).toBe("")
    await commands(dir)
    // Nothing the rest of the plugin loads keeps the runner alive once its parts ended.
    const runner = (await Bun.file(path.join(dir, "runner.json")).json()) as { pid: number }
    await waitFor(async () => (await liveness(runner.pid)).state === "dead", 5_000)
  }, 30_000)

  test("in a reused folder a build broken by a stale cache is built once more from clean", async () => {
    const context = await setup()
    const first = await launch(context, { job: "j-nnnnnnnn" })
    await until(context.launcher, first.key, ended)
    await reaped(context)
    const second = await launch(context, { job: "j-pppppppp", args: ["--falha-com-cache"] })
    const status = await until(context.launcher, second.key, ended)
    if (status.state !== "done") throw new Error(JSON.stringify(status))
    expect(judge(status.ending).verdict).toBe("aprovado")
    expect((await events(second.dir)).some((event) => event.type === "build.clean")).toBe(true)
    // A build that fails in a fresh folder (the second is still held) is a compile error at once.
    const fresh = await launch(context, { job: "j-qqqqqqqq", args: ["--falha-build"] })
    const failed = await until(context.launcher, fresh.key, ended)
    if (failed.state !== "done") throw new Error(JSON.stringify(failed))
    expect(judge(failed.ending)).toMatchObject({ verdict: "compilacao" })
    expect((await events(fresh.dir)).some((event) => event.type === "build.clean")).toBe(false)
    await Promise.all([first.dir, second.dir, fresh.dir].map(commands))
  }, 30_000)
})
