import type { Database } from "bun:sqlite"
import fs from "node:fs/promises"
import path from "node:path"
import type { Git } from "./git.js"
import { ref } from "./snapshot.js"

/** A working folder; `reused`: an earlier execution used it (its build may be stale: one clean rebuild on failure). */
export type Workdir = {
  readonly id: string
  readonly project: string
  readonly path: string
  readonly reused?: boolean
}

/** Where a request's commit may come from, tried in this order (`docs/bancada.md`, "Frozen code"). */
export type Sources = {
  readonly job: string
  /** The session's repository on this machine: nothing travels. */
  readonly local?: { readonly repository: string }
  /** The project's remote, when the origin said a remote has the commit; this machine's own credentials. */
  readonly remote?: { readonly url: string }
  /** A git bundle the origin made, received through the hub. */
  readonly bundle?: { readonly file: string }
}

export type Fetched =
  | { readonly ok: true; readonly via: "present" | "local" | "remote" | "bundle" }
  | { readonly ok: false; readonly tried: ReadonlyArray<string> }

type Row = {
  readonly id: string
  readonly project: string
  readonly path: string
  readonly busy_by: string | null
  readonly last_commit: string | null
  readonly last_used_at: number
}

export const limits = { unusedMs: 14 * 86_400_000 }

/**
 * The executor's working folders (`work/<project>/<n>/`): one git repository each, used by one attempt group at a
 * time. A new folder is made only when every folder of the project is busy; a free one that last held the same commit
 * is preferred, then the most recently used (its build caches are the freshest).
 */
export function makeWorkdirs(input: {
  readonly db: Database
  readonly root: string
  readonly now: () => number
  readonly random: () => string
  readonly git: Git
}) {
  const db = input.db
  const git = input.git
  const byProject = db.query<Row, [string]>("SELECT * FROM workdir WHERE project = ? ORDER BY path")

  /** Idempotent per owner: a start repeated after a restart gets back the folder its first try took. */
  const acquire = async (project: string, commit: string, owner: string): Promise<Workdir> => {
    const chosen = db.transaction(() => {
      const held = byProject.all(project).find((row) => row.busy_by === owner)
      if (held) return { row: held, fresh: false }
      const free = byProject
        .all(project)
        .filter((row) => row.busy_by === null)
        .toSorted(
          (a, b) =>
            Number(b.last_commit === commit) - Number(a.last_commit === commit) || b.last_used_at - a.last_used_at,
        )[0]
      if (free) {
        db.run("UPDATE workdir SET busy_by = ?, last_used_at = ? WHERE id = ?", [owner, input.now(), free.id])
        return { row: free, fresh: false }
      }
      const taken = new Set(byProject.all(project).map((row) => row.path))
      const folder = path.join(input.root, slug(project))
      const next = Array.from({ length: taken.size + 1 }, (_, index) => path.join(folder, String(index + 1))).find(
        (candidate) => !taken.has(candidate),
      )!
      const row = {
        id: input.random(),
        project,
        path: next,
        busy_by: owner,
        last_commit: null,
        last_used_at: input.now(),
      }
      db.run("INSERT INTO workdir (id, project, path, busy_by, last_commit, last_used_at) VALUES (?, ?, ?, ?, ?, ?)", [
        row.id,
        row.project,
        row.path,
        row.busy_by,
        row.last_commit,
        row.last_used_at,
      ])
      return { row, fresh: true }
    })()
    if (chosen.fresh || !(await fs.exists(path.join(chosen.row.path, ".git")))) {
      await fs.mkdir(chosen.row.path, { recursive: true })
      await git(["init", "--quiet"], { cwd: chosen.row.path })
    }
    return { id: chosen.row.id, project, path: chosen.row.path, reused: chosen.row.last_commit !== null }
  }

  const release = (workdir: Workdir, commit?: string) =>
    db.run("UPDATE workdir SET busy_by = NULL, last_used_at = ?, last_commit = COALESCE(?, last_commit) WHERE id = ?", [
      input.now(),
      commit ?? null,
      workdir.id,
    ])

  const has = async (workdir: Workdir, commit: string) =>
    (await git(["cat-file", "-e", `${commit}^{commit}`], { cwd: workdir.path })).code === 0

  /**
   * Brings the commit into the folder, stopping at the first source that works; each keeps it under
   * `refs/bancada/<job>` until cleanup. A bundle is verified before anything is taken from it.
   */
  const fetch = async (workdir: Workdir, commit: string, sources: Sources): Promise<Fetched> => {
    if (await has(workdir, commit)) {
      await git(["update-ref", ref(sources.job), commit], { cwd: workdir.path })
      return { ok: true, via: "present" }
    }
    const into = `+${ref(sources.job)}:${ref(sources.job)}`
    /** One git command; the last line of its error when it fails. */
    const step = async (args: string[]) => {
      const result = await git(args, { cwd: workdir.path })
      return result.code === 0
        ? undefined
        : result.stderr.trim().split("\n").slice(-1)[0] || `git saiu com ${result.code}`
    }
    const attempts: { via: "local" | "remote" | "bundle"; run: () => Promise<string | undefined> }[] = [
      ...(sources.local
        ? [{ via: "local" as const, run: () => step(["fetch", "--no-tags", sources.local!.repository, into]) }]
        : []),
      ...(sources.remote
        ? [
            {
              via: "remote" as const,
              run: () => step(["fetch", "--no-tags", sources.remote!.url, `+${commit}:${ref(sources.job)}`]),
            },
          ]
        : []),
      ...(sources.bundle
        ? [
            {
              via: "bundle" as const,
              run: async () =>
                (await step(["bundle", "verify", "--quiet", sources.bundle!.file])) ??
                step(["fetch", "--no-tags", sources.bundle!.file, into]),
            },
          ]
        : []),
    ]
    const tried: string[] = []
    for (const attempt of attempts) {
      const failure = await attempt.run()
      if (failure === undefined && (await has(workdir, commit))) return { ok: true, via: attempt.via }
      tried.push(`${attempt.via}: ${failure ?? "o commit não veio"}`)
    }
    return { ok: false, tried }
  }

  return {
    acquire,
    release,
    fetch,
    /** The commits this machine already has of a project: the tips of its folders, for a smaller bundle. */
    have: async (project: string) => {
      const tips = await Promise.all(
        byProject.all(project).map(async (row) => {
          const refs = await git(["for-each-ref", "--format=%(objectname)"], { cwd: row.path })
          const head = await git(["rev-parse", "--verify", "--quiet", "HEAD"], { cwd: row.path })
          return [...refs.stdout.split("\n"), head.stdout].map((line) => line.trim()).filter(Boolean)
        }),
      )
      return [...new Set(tips.flat())]
    },
    /** A delivered request's commit no longer needs holding here. */
    forget: (workdir: Workdir, job: string) => git(["update-ref", "-d", ref(job)], { cwd: workdir.path }),
    /** Folders nobody used for `limits.unusedMs` are removed (their caches with them). */
    prune: async () => {
      const old = db
        .query<Row, [number]>("SELECT * FROM workdir WHERE busy_by IS NULL AND last_used_at < ?")
        .all(input.now() - limits.unusedMs)
      for (const row of old) {
        await fs.rm(row.path, { recursive: true, force: true })
        db.run("DELETE FROM workdir WHERE id = ? AND busy_by IS NULL", [row.id])
      }
      return old.length
    },
  }
}

export type Workdirs = ReturnType<typeof makeWorkdirs>

/**
 * How the runner prepares a folder for a commit: the commit checked out (local changes discarded) and everything
 * untracked removed but the contract's `caches`. As argv lists, so the runner, a single file, only executes them.
 */
export function prepareCommands(commit: string, caches: ReadonlyArray<string>): string[][] {
  return [
    ["git", "checkout", "--quiet", "--force", "--detach", commit],
    ["git", "clean", "-fdxq", ...caches.flatMap((cache) => ["-e", cache])],
  ]
}

/** After a build failed in a reused folder: everything untracked removed, caches included, to build once more clean. */
export function scrubCommands(): string[][] {
  return [["git", "clean", "-fdxq"]]
}

/** A project name as a folder name. */
function slug(project: string) {
  return project.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^[.-]+/, "") || "projeto"
}
