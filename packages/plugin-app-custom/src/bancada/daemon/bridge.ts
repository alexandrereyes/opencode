import { machineID, parsePlatformUUID } from "../../resources/machine.js"

/**
 * A machine's hardware identity, from a command that prints its `IOPlatformUUID` (`ioreg`, here or through the `mac`
 * bridge; the machine file's `[pontes]`): the same hash `resources/machine.ts` publishes, so the raw UUID never leaves
 * the machine. Read only; `undefined` when the command is missing, fails or prints no UUID.
 */
export async function identify(command: ReadonlyArray<string>, timeoutMs = 10_000) {
  const output = await Promise.resolve()
    .then(async () => {
      const child = Bun.spawn([...command], { stdin: "ignore", stdout: "pipe", stderr: "ignore", timeout: timeoutMs })
      const [text, code] = await Promise.all([new Response(child.stdout).text(), child.exited])
      return code === 0 ? text : ""
    })
    .catch(() => "")
  const uuid = parsePlatformUUID(output)
  return uuid ? machineID(uuid) : undefined
}
