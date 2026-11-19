/**
 * What the system says about a process: `alive` with its start time, `dead` with proof, or `unknown` when it could not
 * be asked. With the pid, the start time is the process's identity: a reused pid has another one. Never the command
 * line, never the parent (when a parent dies its children's ppid becomes 1 and a live process would look dead, prova
 * E1). `unknown` is never `dead`: on a Mac at load 600 a `ps` that misses its deadline or a `fork` that fails is the
 * expected case; whoever asked keeps what it knew and asks again next time (`docs/bancada.md`, "Execution").
 */
export type Liveness =
  | { readonly state: "alive"; readonly started: string }
  | { readonly state: "dead" }
  | { readonly state: "unknown" }

const dead: Liveness = { state: "dead" }
const unknown: Liveness = { state: "unknown" }

/** Deadline of one `ps` on macOS. */
export const psTimeoutMs = 5_000

export async function liveness(pid: number, platform: NodeJS.Platform = process.platform): Promise<Liveness> {
  if (!Number.isInteger(pid) || pid <= 0) return dead
  const signal = signalZero(pid)
  if (signal === "absent") return dead
  if (platform === "linux")
    return fromStat(
      await Bun.file(`/proc/${pid}/stat`)
        .text()
        .then(
          (text) => ({ text }),
          (error: unknown) => ({ error: code(error) }),
        ),
    )
  return fromPs(await ps(pid))
}

/**
 * `/proc/<pid>/stat`: the state is field 3 and the start time field 22, counted after the command name. A missing
 * file is proof the process is gone; any other failure to read it is not.
 */
export function fromStat(read: { readonly text: string } | { readonly error: string | undefined }): Liveness {
  if ("error" in read) return read.error === "ENOENT" || read.error === "ESRCH" ? dead : unknown
  // The command name sits in parentheses and may hold spaces and parentheses itself.
  const close = read.text.lastIndexOf(")")
  if (close < 0) return unknown
  const fields = read.text.slice(close + 2).split(" ")
  if (fields[0] === "Z" || fields[0] === "X") return dead
  const started = fields[19]
  return started ? { state: "alive", started } : unknown
}

/**
 * `ps -o stat=,lstart= -p <pid>` on macOS (`S    Thu Nov 19 17:31:12 2026`). Exit 1 with nothing printed is proof the
 * process is gone; a `ps` that did not run, missed its deadline or failed otherwise is not.
 */
export function fromPs(result: { readonly code: number; readonly stdout: string } | undefined): Liveness {
  if (!result) return unknown
  const line = result.stdout.trim()
  if (result.code === 1 && line === "") return dead
  if (result.code !== 0 || line === "") return unknown
  if (line.startsWith("Z")) return dead
  const space = line.search(/\s/)
  const started = space < 0 ? "" : line.slice(space).trim()
  return started ? { state: "alive", started } : unknown
}

/** `kill(pid, 0)`: `ESRCH` proves the pid does not exist; `EPERM` means it exists and belongs to someone else. */
function signalZero(pid: number): "present" | "absent" | "unknown" {
  try {
    process.kill(pid, 0)
    return "present"
  } catch (error) {
    if (code(error) === "ESRCH") return "absent"
    return code(error) === "EPERM" ? "present" : "unknown"
  }
}

async function ps(pid: number) {
  const child = spawn(["/bin/ps", "-o", "stat=,lstart=", "-p", String(pid)])
  if (!child) return undefined
  const [stdout, exit] = await Promise.all([new Response(child.stdout).text(), child.exited])
  // Killed by the deadline: no answer.
  return child.signalCode ? undefined : { code: exit, stdout }
}

/** A `fork` that fails (the Mac out of processes or memory) is no answer, not an error to raise. */
function spawn(argv: string[]) {
  try {
    return Bun.spawn(argv, { stdin: "ignore", stdout: "pipe", stderr: "ignore", timeout: psTimeoutMs })
  } catch {
    return undefined
  }
}

function code(error: unknown) {
  return typeof error === "object" && error !== null && "code" in error && typeof error.code === "string"
    ? error.code
    : undefined
}
