import { createHash, randomUUID } from "node:crypto"
import { chmod, mkdir, rename, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { onMac } from "./custom-release"
import { bundleID, signingSubject } from "./custom-signing"

type Mac = (args: string[]) => Promise<{ stdout: string; stderr: string; code: number }>

/**
 * On a Linux runtime, commands that need the Mac (an MCP server, say) run through `mac`, so on the Mac they descend
 * from OrbStack Helper. Native helpers that only trust descendants of the signed OpenCode server (identifier
 * `local.opencode.custom` with the persistent local certificate; MacLock, for Computer Use while the Mac is locked)
 * refuse them. `bin/mac-controller`, compiled and signed on the Mac with that identity, runs a command as its child
 * and stays its parent:
 *
 *   mac ~/.local/share/opencode-custom-v2/bin/mac-controller node /path/to/mcp-server.js
 *
 * It grants nothing a process of this user lacks: the signing keychain belongs to this user, with an empty password.
 * Rebuilt when the source changes or the installed signature no longer verifies.
 */
export async function installMacController(
  host: { home: string; mac: Mac } = { home: `/Users/${os.userInfo().username}`, mac: onMac },
) {
  const runtime = path.join(host.home, ".local/share/opencode-custom-v2")
  const keychain = path.join(runtime, "signing/signing.keychain-db")
  if (!(await Bun.file(keychain).exists())) return `mac controller skipped (${keychain} missing)`
  const target = path.join(runtime, "bin/mac-controller")
  const source = await Bun.file(path.join(import.meta.dirname, "custom-mac-controller.c")).text()
  const digest = createHash("sha256").update(source).digest("hex")
  const stamp = `${target}.sha256`
  const installed = await Bun.file(stamp)
    .text()
    .catch(() => "")
  // Programs by name: `mac` rewrites every argument starting with `/` (except `/Users`) as a Linux path.
  if (installed.trim() === digest && (await host.mac(["codesign", "--verify", "--strict", target])).code === 0)
    return "mac controller unchanged"
  const work = path.join(runtime, `.mac-controller-${randomUUID()}`)
  await mkdir(work, { recursive: true, mode: 0o700 })
  try {
    const file = path.join(work, "mac-controller.c")
    const binary = path.join(work, "mac-controller")
    await Bun.write(file, source)
    await run(host.mac, ["clang", "-O2", "-Wall", "-Werror", "-o", binary, file])
    await run(host.mac, ["security", "unlock-keychain", "-p", "", keychain])
    const identity = (await run(host.mac, ["security", "find-identity", "-p", "codesigning", keychain])).match(
      new RegExp(`\\b([A-F0-9]{40}) "${signingSubject}"`),
    )?.[1]
    if (!identity) throw new Error(`Signing identity "${signingSubject}" is missing from ${keychain}`)
    await run(host.mac, [
      "codesign",
      "--force",
      "--sign",
      identity,
      "--identifier",
      bundleID,
      "--keychain",
      keychain,
      binary,
    ])
    await run(host.mac, ["codesign", "--verify", "--strict", binary])
    // `mac` processes run without a umask: clang leaves the executable writable by every user.
    await chmod(binary, 0o755)
    await mkdir(path.dirname(target), { recursive: true })
    await rename(binary, target)
    await Bun.write(stamp, `${digest}\n`)
    await chmod(stamp, 0o644)
  } finally {
    await rm(work, { recursive: true, force: true })
  }
  return "mac controller installed"
}

async function run(mac: Mac, args: string[]) {
  const result = await mac(args)
  if (result.code !== 0) throw new Error(`${args[0]} failed through mac (${result.code}): ${result.stderr.trim()}`)
  return result.stdout
}
