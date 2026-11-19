export type GitResult = { readonly code: number; readonly stdout: string; readonly stderr: string }

/** One `git` command; never throws for a failing command (its code says so). */
export type Git = (
  args: ReadonlyArray<string>,
  options: { readonly cwd: string; readonly env?: Readonly<Record<string, string>>; readonly timeoutMs?: number },
) => Promise<GitResult>

/** Deadline of one command unless the caller gives another; a fetch of a large repository can take minutes. */
export const gitTimeoutMs = 10 * 60_000

/**
 * The real `git`. The environment drops every inherited `GIT_*` (a hook's `GIT_INDEX_FILE` or `GIT_DIR` would point
 * the command elsewhere) and never prompts for credentials: a fetch that needs them fails instead of hanging.
 */
export const runGit: Git = async (args, options) => {
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("GIT_")))
  const child = spawn(["git", ...args], {
    cwd: options.cwd,
    env: { ...env, GIT_TERMINAL_PROMPT: "0", ...options.env },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    timeout: options.timeoutMs ?? gitTimeoutMs,
  })
  if (child instanceof Error) return { code: 127, stdout: "", stderr: child.message }
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ])
  return { code, stdout, stderr }
}

/** A command that cannot start (a missing folder, no `git`) is a failed command, not an exception. */
function spawn(argv: string[], options: Bun.SpawnOptions.OptionsObject<"ignore", "pipe", "pipe">) {
  try {
    return Bun.spawn(argv, options)
  } catch (error) {
    return error instanceof Error ? error : new Error(String(error))
  }
}
