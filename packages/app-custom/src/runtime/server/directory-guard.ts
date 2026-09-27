import type { Data } from "@opencode/client/solid"

export function createDirectoryGuard(check: (directory: string) => Promise<boolean>) {
  const cached = new Map<string, Promise<boolean>>()
  function available(directory: string) {
    if (!directory) return Promise.resolve(true)
    const pending = cached.get(directory)
    if (pending) return pending
    // An unavailable plugin or failed probe is not evidence of a missing directory.
    const result = check(directory).catch(() => true)
    cached.set(directory, result)
    return result
  }
  return {
    available,
    clear: () => cached.clear(),
    async run(directory: string, load: () => Promise<void>) {
      if (!(await available(directory))) return
      const checked = cached.get(directory)
      return load().catch(async (error: unknown) => {
        // A directory can disappear after its cold check. Concurrent catalog failures
        // share one new probe; unrelated errors still reach the normal error handler.
        if (cached.get(directory) === checked) cached.delete(directory)
        if (!(await available(directory))) return
        throw error
      })
    },
  }
}

export function guardLocationSync(data: Data, guard: ReturnType<typeof createDirectoryGuard>) {
  // Mutate the returned resource methods so createData's event-driven refreshes use
  // the same guard as UI callers. Session/history resources deliberately stay independent.
  for (const resource of [
    data.location,
    data.location.vcs,
    data.location.agent,
    data.location.command,
    data.location.config,
    data.location.integration,
    data.location.mcp.server,
    data.location.mcp.resource,
    data.location.model,
    data.location.provider,
    data.location.reference,
    data.location.skill,
    data.shell,
  ]) {
    const sync = resource.sync
    resource.sync = (ref) => guard.run(ref?.directory ?? data.location.default().directory, () => sync(ref))
  }
  const syncInfo = data.location.syncInfo
  data.location.syncInfo = (ref) => guard.run(ref?.directory ?? data.location.default().directory, () => syncInfo(ref))
  const websearch = data.location.websearch.refresh
  data.location.websearch.refresh = (ref) =>
    guard.run(ref?.directory ?? data.location.default().directory, () => websearch(ref))
  const forms = data.session.form.sync
  data.session.form.sync = (sessionID, ref) =>
    sessionID === "global"
      ? guard.run(ref?.directory ?? data.location.default().directory, () => forms(sessionID, ref))
      : forms(sessionID, ref)
}
