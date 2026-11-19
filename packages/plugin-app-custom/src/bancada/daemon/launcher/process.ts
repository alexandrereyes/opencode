import { text } from "../../../resources/adapters/process.js"

/**
 * When a process started, as the system reports it, or undefined when it does not exist (or is a zombie). With the
 * pid it is the process's identity: a reused pid has another start time. Never the command line, never the parent:
 * when a parent dies its children's ppid becomes 1 and a live process would look dead (prova E1).
 */
export async function startTime(pid: number, platform: NodeJS.Platform = process.platform) {
  if (!Number.isInteger(pid) || pid <= 0) return undefined
  if (platform === "linux")
    return linuxStart(
      await Bun.file(`/proc/${pid}/stat`)
        .text()
        .catch(() => undefined),
    )
  return darwinStart(
    await text(["/bin/ps", "-o", "stat=,lstart=", "-p", String(pid)], { timeout: 5_000 }).catch(() => undefined),
  )
}

/** `/proc/<pid>/stat`: the state is field 3 and the start time field 22, counted after the command name. */
export function linuxStart(stat: string | undefined) {
  if (!stat) return undefined
  // The command name sits in parentheses and may hold spaces and parentheses itself.
  const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ")
  if (fields[0] === "Z" || fields[0] === "X") return undefined
  return fields[19] || undefined
}

/** `ps -o stat=,lstart=` on macOS: `S    Thu Nov 19 17:31:12 2026`. */
export function darwinStart(line: string | undefined) {
  const trimmed = line?.trim()
  if (!trimmed || trimmed.startsWith("Z")) return undefined
  const space = trimmed.search(/\s/)
  return space < 0 ? undefined : trimmed.slice(space).trim() || undefined
}
