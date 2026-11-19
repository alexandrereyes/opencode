import { Database } from "bun:sqlite"
import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { runGit } from "../src/bancada/daemon/git"
import { migrate } from "../src/bancada/daemon/schema"
import { bundle, freeze, ref, release } from "../src/bancada/daemon/snapshot"
import { makeWorkdirs, prepareCommands, scrubCommands } from "../src/bancada/daemon/workdir"
import { initGit } from "../../core/test/fixture/git"

const example = path.join(import.meta.dir, "fixture/bancada-exemplo")
const folders: string[] = []
afterEach(() => Promise.all(folders.splice(0).map((folder) => fs.rm(folder, { recursive: true, force: true }))))

const git = async (cwd: string, ...args: string[]) => {
  const result = await runGit(args, { cwd })
  if (result.code !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr}`)
  return result.stdout.trim()
}
/** The example project as a fresh repository with one commit, in a folder of its own. */
async function project() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-code-"))
  folders.push(root)
  const repository = path.join(root, "projeto")
  await fs.cp(example, repository, { recursive: true })
  await initGit(repository)
  await git(repository, "add", "-A")
  await git(repository, "commit", "-q", "-m", "exemplo")
  return { root, repository }
}
function workdirs(root: string, now = () => 1_000) {
  const db = new Database(":memory:")
  migrate(db)
  let n = 0
  return {
    db,
    workdirs: makeWorkdirs({ db, root: path.join(root, "work"), now, random: () => `w-${++n}`, git: runGit }),
  }
}
async function execute(cwd: string, commands: string[][]) {
  for (const argv of commands) {
    const child = Bun.spawn(argv, { cwd, stdout: "ignore", stderr: "pipe" })
    if ((await child.exited) !== 0) throw new Error(`${argv.join(" ")}: ${await new Response(child.stderr).text()}`)
  }
}

describe("frozen code", () => {
  test("a snapshot takes new and changed files, leaves ignored ones out, and touches neither working tree nor index", async () => {
    const { repository } = await project()
    const head = await git(repository, "rev-parse", "HEAD")
    await fs.appendFile(path.join(repository, "scripts/run"), "# alterado\n")
    await Bun.write(path.join(repository, "novo.txt"), "arquivo novo\n")
    await Bun.write(path.join(repository, "preparado.txt"), "no índice de verdade\n")
    await git(repository, "add", "preparado.txt")
    await Bun.write(path.join(repository, "ignorado.txt"), "fora do snapshot\n")
    const before = await git(repository, "status", "--porcelain")

    const frozen = await freeze({
      git: runGit,
      directory: path.join(repository, "scripts"),
      job: "j-7qk2m9xa",
      snapshot: true,
    })
    if (!frozen.ok) throw new Error(frozen.problems.join("\n"))
    expect(frozen.frozen.files.toSorted((a, b) => a.path.localeCompare(b.path))).toEqual([
      { path: "novo.txt", change: "novo" },
      { path: "preparado.txt", change: "novo" },
      { path: "scripts/run", change: "alterado" },
    ])
    expect(frozen.frozen).toMatchObject({ root: repository, project: "bancada-exemplo", inRemote: false })
    expect(Object.keys(frozen.frozen.contract.tests)).toContain("simples")
    expect(await git(repository, "status", "--porcelain")).toBe(before)
    expect(await git(repository, "rev-parse", "HEAD")).toBe(head)
    expect(await git(repository, "rev-parse", `${frozen.frozen.commit}^`)).toBe(head)
    expect(await git(repository, "rev-parse", ref("j-7qk2m9xa"))).toBe(frozen.frozen.commit)
    expect(await git(repository, "show", `${frozen.frozen.commit}:novo.txt`)).toBe("arquivo novo")
    expect(await runGit(["cat-file", "-e", `${frozen.frozen.commit}:ignorado.txt`], { cwd: repository })).toMatchObject(
      { code: 128 },
    )
    expect(await fs.readdir(path.join(repository, ".git"))).not.toContainEqual(expect.stringContaining("bancada-"))

    await release(runGit, repository, "j-7qk2m9xa")
    expect((await runGit(["rev-parse", "--verify", ref("j-7qk2m9xa")], { cwd: repository })).code).not.toBe(0)
  })

  test("a clean tree freezes HEAD itself; without snapshot, HEAD is frozen and what stays out is counted", async () => {
    const { repository } = await project()
    const head = await git(repository, "rev-parse", "HEAD")
    expect(await freeze({ git: runGit, directory: repository, job: "j-aaaaaaaa", snapshot: true })).toMatchObject({
      ok: true,
      frozen: { commit: head, files: [] },
    })
    await fs.appendFile(path.join(repository, "scripts/run"), "# alterado\n")
    await Bun.write(path.join(repository, "novo.txt"), "x\n")
    const frozen = await freeze({ git: runGit, directory: repository, job: "j-bbbbbbbb", snapshot: false })
    expect(frozen).toMatchObject({ ok: true, frozen: { commit: head, files: [], notIncluded: 2 } })
  })

  test.each([
    ["a folder outside any repository", async () => (await project()).root, "não está num repositório git"],
    [
      "a commit without .bancada.toml",
      async () => {
        const { repository } = await project()
        await git(repository, "rm", "-q", ".bancada.toml")
        await git(repository, "commit", "-q", "-m", "sem contrato")
        return repository
      },
      "não tem .bancada.toml na raiz",
    ],
    [
      "an invalid contract",
      async () => {
        const { repository } = await project()
        await Bun.write(
          path.join(repository, ".bancada.toml"),
          'versao = 1\n[teste.a]\nprecisa = ["android"]\nrun = "scripts/nao-existe"\n',
        )
        await git(repository, "commit", "-q", "-am", "contrato quebrado")
        return repository
      },
      'teste.a.run: "scripts/nao-existe" não existe neste commit',
    ],
  ])("freezes nothing for %s", async (_name, setup, problem) => {
    const directory = await setup()
    const frozen = await freeze({ git: runGit, directory, job: "j-cccccccc", snapshot: false })
    expect(frozen.ok ? [] : frozen.problems.join("\n")).toContain(problem)
    expect((await runGit(["rev-parse", "--verify", ref("j-cccccccc")], { cwd: directory })).code).not.toBe(0)
  })

  test("the remotes go without credentials, and say whether one of them already has the commit", async () => {
    const { root, repository } = await project()
    const remote = path.join(root, "remote.git")
    await git(root, "init", "-q", "--bare", remote)
    await git(repository, "remote", "add", "origin", "https://x-access-token:segredo@github.com/dono/exemplo.git")
    await git(repository, "remote", "add", "espelho", pathToFileURL(remote).href)
    await git(repository, "push", "-q", "espelho", "HEAD:refs/heads/main")
    await git(repository, "fetch", "-q", "espelho")
    const pushed = await freeze({ git: runGit, directory: repository, job: "j-dddddddd", snapshot: false })
    expect(pushed).toMatchObject({
      ok: true,
      frozen: { remotes: ["https://github.com/dono/exemplo.git", pathToFileURL(remote).href], inRemote: true },
    })
    await Bun.write(path.join(repository, "novo.txt"), "x\n")
    expect(await freeze({ git: runGit, directory: repository, job: "j-eeeeeeee", snapshot: true })).toMatchObject({
      ok: true,
      frozen: { inRemote: false },
    })
  })
})

describe("working folders", () => {
  test("the commit reaches a folder from the session's repository, from a remote, or from a bundle of what it lacks", async () => {
    const { root, repository } = await project()
    const { workdirs: folders } = workdirs(root)
    // Same machine: straight from the session's repository.
    const first = await freeze({ git: runGit, directory: repository, job: "j-aaaaaaaa", snapshot: false })
    if (!first.ok) throw new Error(first.problems.join("\n"))
    const folder = await folders.acquire("bancada-exemplo", first.frozen.commit, "j-aaaaaaaa/g1")
    expect(await folders.fetch(folder, first.frozen.commit, { job: "j-aaaaaaaa", local: { repository } })).toEqual({
      ok: true,
      via: "local",
    })
    expect(await folders.fetch(folder, first.frozen.commit, { job: "j-aaaaaaaa" })).toEqual({
      ok: true,
      via: "present",
    })

    // A remote that has the commit.
    const remote = path.join(root, "remote.git")
    await git(root, "init", "-q", "--bare", remote)
    await git(repository, "commit", "-q", "--allow-empty", "-m", "no remoto")
    await git(repository, "push", "-q", pathToFileURL(remote).href, "HEAD:refs/heads/main")
    const second = await freeze({ git: runGit, directory: repository, job: "j-bbbbbbbb", snapshot: false })
    if (!second.ok) throw new Error(second.problems.join("\n"))
    expect(
      await folders.fetch(folder, second.frozen.commit, {
        job: "j-bbbbbbbb",
        remote: { url: pathToFileURL(remote).href },
      }),
    ).toEqual({ ok: true, via: "remote" })
    folders.release(folder, second.frozen.commit)

    // Another machine: a bundle with only what this folder lacks.
    await Bun.write(path.join(repository, "grande.bin"), Buffer.alloc(200_000, 1))
    const third = await freeze({ git: runGit, directory: repository, job: "j-cccccccc", snapshot: true })
    if (!third.ok) throw new Error(third.problems.join("\n"))
    const have = await folders.have("bancada-exemplo")
    expect(have).toContain(second.frozen.commit)
    const thin = path.join(root, "thin.bundle")
    const full = path.join(root, "full.bundle")
    expect(await bundle(runGit, repository, "j-cccccccc", have, thin)).toBe(true)
    expect(await bundle(runGit, repository, "j-cccccccc", [], full)).toBe(true)
    expect((await fs.stat(thin)).size).toBeLessThan((await fs.stat(full)).size)
    const again = await folders.acquire("bancada-exemplo", third.frozen.commit, "j-cccccccc/g1")
    expect(again.path).toBe(folder.path)
    expect(await folders.fetch(again, third.frozen.commit, { job: "j-cccccccc", bundle: { file: thin } })).toEqual({
      ok: true,
      via: "bundle",
    })
    // A folder without the bundle's prerequisites refuses it before taking anything.
    const empty = await folders.acquire("bancada-exemplo", third.frozen.commit, "j-cccccccc/g2")
    expect(empty.path).not.toBe(folder.path)
    const refused = await folders.fetch(empty, third.frozen.commit, { job: "j-cccccccc", bundle: { file: thin } })
    expect(refused).toMatchObject({ ok: false, tried: [expect.stringContaining("bundle:")] })
  })

  test("a free folder that held the commit is preferred, a busy one never shared, an unused one pruned", async () => {
    const { root } = await project()
    let now = 1_000
    const { workdirs: folders } = workdirs(root, () => now)
    const a = await folders.acquire("exemplo", "c1", "j-1/g1")
    const b = await folders.acquire("exemplo", "c1", "j-2/g1")
    expect(b.path).not.toBe(a.path)
    folders.release(a, "c1")
    now += 10
    folders.release(b, "c2")
    // `b` was used last, but `a` held the commit asked for.
    expect((await folders.acquire("exemplo", "c1", "j-3/g1")).path).toBe(a.path)
    now += 15 * 86_400_000
    expect(await folders.prune()).toBe(1)
    expect(await fs.exists(b.path)).toBe(false)
    expect(await fs.exists(a.path)).toBe(true)
  })

  test("preparing keeps the caches and drops the rest; scrubbing drops the caches too", async () => {
    const { root, repository } = await project()
    const { workdirs: folders } = workdirs(root)
    const frozen = await freeze({ git: runGit, directory: repository, job: "j-aaaaaaaa", snapshot: false })
    if (!frozen.ok) throw new Error(frozen.problems.join("\n"))
    const folder = await folders.acquire("bancada-exemplo", frozen.frozen.commit, "j-aaaaaaaa/g1")
    await folders.fetch(folder, frozen.frozen.commit, { job: "j-aaaaaaaa", local: { repository } })
    const prepare = prepareCommands(frozen.frozen.commit, frozen.frozen.contract.caches)
    await execute(folder.path, prepare)
    await Bun.write(path.join(folder.path, "cache/compilado"), "do build anterior\n")
    await Bun.write(path.join(folder.path, "lixo.txt"), "de uma execução anterior\n")
    await fs.appendFile(path.join(folder.path, "scripts/run"), "# mexido pela execução anterior\n")

    await execute(folder.path, prepare)
    expect(await fs.exists(path.join(folder.path, "cache/compilado"))).toBe(true)
    expect(await fs.exists(path.join(folder.path, "lixo.txt"))).toBe(false)
    expect(await git(folder.path, "status", "--porcelain")).toBe("")

    await execute(folder.path, scrubCommands())
    expect(await fs.exists(path.join(folder.path, "cache"))).toBe(false)
  })
})
