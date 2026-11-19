import fs from "node:fs/promises"
import path from "node:path"
import { normalizeRemote, parseContract, type Contract } from "../contract.js"
import type { Git } from "./git.js"

/** A file of the session's working tree that entered the frozen commit, against `HEAD`. */
export type Change = { readonly path: string; readonly change: "novo" | "alterado" | "removido" }

export type Frozen = {
  readonly root: string
  readonly commit: string
  /** With `snapshot`: what entered beyond `HEAD`, new files included. */
  readonly files: ReadonlyArray<Change>
  /** Without `snapshot`: how many changed files of the working tree were left out. */
  readonly notIncluded?: number
  readonly project: string
  /** The project's remotes, without credentials. */
  readonly remotes: ReadonlyArray<string>
  /** Whether a remote-tracking branch already holds the commit (another machine may fetch it there). */
  readonly inRemote: boolean
  readonly contract: Contract
}

export type Freeze =
  | { readonly ok: true; readonly frozen: Frozen }
  | { readonly ok: false; readonly problems: string[] }

const author = {
  GIT_AUTHOR_NAME: "Bancada",
  GIT_AUTHOR_EMAIL: "bancada@localhost",
  GIT_COMMITTER_NAME: "Bancada",
  GIT_COMMITTER_EMAIL: "bancada@localhost",
}

/** The ref that holds a request's commit in the session's repository until delivery. */
export const ref = (job: string) => `refs/bancada/${job}`

/**
 * Freezes a request's code in the session's own repository (`docs/bancada.md`, "Frozen code"), without touching its
 * working tree or index. `snapshot`: the working tree as it is, new files included and ignored ones out, as a commit
 * on top of `HEAD` built in a temporary index (or `HEAD` itself when nothing changed); otherwise `commit` (`HEAD` by
 * default), saying how many changes stay out. The commit is held by `refs/bancada/<job>` and its `.bancada.toml` must
 * be valid; when it is not, the ref is removed and nothing goes on.
 */
export async function freeze(input: {
  readonly git: Git
  readonly directory: string
  readonly job: string
  readonly snapshot: boolean
  readonly commit?: string
}): Promise<Freeze> {
  const git = input.git
  const top = await git(["rev-parse", "--show-toplevel"], { cwd: input.directory })
  if (top.code !== 0) return refused(`${input.directory} não está num repositório git`)
  const root = top.stdout.trim()
  const head = await git(["rev-parse", "--verify", "HEAD^{commit}"], { cwd: root })
  if (head.code !== 0) return refused("o repositório ainda não tem nenhum commit")
  const chosen = input.snapshot
    ? await snapshot(git, root, input.job, head.stdout.trim())
    : await existing(git, root, input.commit ?? "HEAD")
  if ("problem" in chosen) return refused(chosen.problem)
  const commit = chosen.commit
  await git(["update-ref", ref(input.job), commit], { cwd: root })
  const remotes = await urls(git, root)
  const contract = await read(git, root, commit, remotes)
  if (!contract.ok) {
    await release(git, root, input.job)
    return contract
  }
  const contains = await git(["branch", "-r", "--contains", commit], { cwd: root })
  return {
    ok: true,
    frozen: {
      root,
      commit,
      files: chosen.files,
      ...(chosen.notIncluded ? { notIncluded: chosen.notIncluded } : {}),
      project: contract.contract.project,
      remotes: remotes.map(secretless),
      inRemote: contains.code === 0 && contains.stdout.trim() !== "",
      contract: contract.contract,
    },
  }
}

/** Lets the commit of a delivered request go. */
export async function release(git: Git, root: string, job: string) {
  await git(["update-ref", "-d", ref(job)], { cwd: root })
}

/**
 * A git bundle of the request's commit for a machine that has `have` (the tips of its working folders): only the
 * objects it lacks, when the session's repository knows those commits. Returns false when git refused.
 */
export async function bundle(git: Git, root: string, job: string, have: ReadonlyArray<string>, file: string) {
  const known = await Promise.all(
    have.map(async (commit) =>
      (await git(["cat-file", "-e", `${commit}^{commit}`], { cwd: root })).code === 0 ? [commit] : [],
    ),
  )
  const result = await git(["bundle", "create", file, ref(job), "--not", ...known.flat()], { cwd: root })
  return result.code === 0
}

/** The commit chosen to run, or why there is none. */
type Chosen =
  | { readonly problem: string }
  | { readonly commit: string; readonly files: Change[]; readonly notIncluded?: number }

async function snapshot(git: Git, root: string, job: string, head: string): Promise<Chosen> {
  const gitDir = (await git(["rev-parse", "--absolute-git-dir"], { cwd: root })).stdout.trim()
  const index = path.join(gitDir, `bancada-${job}.index`)
  const env = { GIT_INDEX_FILE: index }
  const tree = await (async () => {
    // A temporary index: the session's own index and working tree stay exactly as they are.
    if ((await git(["read-tree", "HEAD"], { cwd: root, env })).code !== 0) return undefined
    if ((await git(["add", "-A"], { cwd: root, env })).code !== 0) return undefined
    const written = await git(["write-tree"], { cwd: root, env })
    return written.code === 0 ? written.stdout.trim() : undefined
  })().finally(() => fs.rm(index, { force: true }))
  if (!tree) return { problem: "não foi possível congelar a árvore de trabalho" }
  const headTree = (await git(["rev-parse", "HEAD^{tree}"], { cwd: root })).stdout.trim()
  if (tree === headTree) return { commit: head, files: [] }
  const made = await git(["commit-tree", tree, "-p", head, "-m", `Bancada ${job}`], {
    cwd: root,
    env: { ...env, ...author },
  })
  if (made.code !== 0) return { problem: "não foi possível criar o commit do snapshot" }
  const commit = made.stdout.trim()
  const diff = await git(["diff", "--name-status", "--no-renames", "-z", head, commit], { cwd: root })
  return { commit, files: changes(diff.stdout) }
}

async function existing(git: Git, root: string, name: string): Promise<Chosen> {
  const found = await git(["rev-parse", "--verify", `${name}^{commit}`], { cwd: root })
  if (found.code !== 0) return { problem: `o commit "${name}" não existe neste repositório` }
  const status = await git(["status", "--porcelain", "-z", "--no-renames"], { cwd: root })
  const notIncluded = status.stdout.split("\0").filter((line) => line.length > 3).length
  return { commit: found.stdout.trim(), files: [], notIncluded }
}

/** The `.bancada.toml` of that commit, checked against the files of that commit. */
async function read(git: Git, root: string, commit: string, remotes: ReadonlyArray<string>) {
  const text = await git(["show", `${commit}:.bancada.toml`], { cwd: root })
  if (text.code !== 0) return refused(`o commit ${commit.slice(0, 8)} não tem .bancada.toml na raiz do repositório`)
  const listed = await git(["ls-tree", "-r", "--name-only", "-z", commit], { cwd: root })
  const files = new Set(listed.stdout.split("\0").filter(Boolean))
  const project = remotes.map(normalizeRemote).find((name) => name !== undefined) ?? path.basename(root)
  return parseContract(text.stdout, { project, exists: (file) => files.has(file) })
}

/** The repository's remote URLs, `origin` first. */
async function urls(git: Git, root: string) {
  const listed = await git(["config", "--get-regexp", "^remote\\..*\\.url$"], { cwd: root })
  const pairs = listed.stdout
    .split("\n")
    .filter(Boolean)
    .map((line) => [line.slice(0, line.indexOf(" ")), line.slice(line.indexOf(" ") + 1)] as const)
  return pairs
    .toSorted(([a], [b]) => Number(b === "remote.origin.url") - Number(a === "remote.origin.url"))
    .map(([, url]) => url)
}

/** A URL without the password or token some remotes carry (`https://user:token@host/…`). */
function secretless(url: string) {
  return url.replace(/^([a-z][a-z0-9+.-]*:\/\/)[^@/]*@/i, "$1")
}

function changes(output: string): Change[] {
  const fields = output.split("\0").filter(Boolean)
  const kinds: Record<string, Change["change"]> = { A: "novo", M: "alterado", T: "alterado", D: "removido" }
  return fields.flatMap((field, index) =>
    index % 2 === 0 && kinds[field[0]!] ? [{ path: fields[index + 1]!, change: kinds[field[0]!]! }] : [],
  )
}

function refused(problem: string): { readonly ok: false; readonly problems: string[] } {
  return { ok: false, problems: [problem] }
}
