import { createHash, randomUUID } from "node:crypto"
import { chmod, mkdir, rename, rm, symlink } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { onMac } from "./custom-release"
import { bundleID, signingSubject } from "./custom-signing"

type Mac = (args: string[]) => Promise<{ stdout: string; stderr: string; code: number }>

export const macControllerBundle = "OpenCode Custom Controller.app"

/**
 * On a Linux runtime, commands that need the Mac (an MCP server, say) run through `mac`, so on the Mac they descend
 * from OrbStack Helper, which is also responsible for their privacy (TCC) checks. Native helpers that only trust
 * descendants of the signed OpenCode server (identifier `local.opencode.custom` with the persistent local certificate;
 * MacLock, for Computer Use while the Mac is locked) refuse them, and Accessibility checks see OrbStack. The Mac
 * runtime's `mac-controller/OpenCode Custom Controller.app`, compiled and signed on the Mac with that identity, runs a
 * command as its child, responsible for it (the server's grants apply), and stays its parent:
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
  const root = path.join(runtime, "mac-controller")
  const app = path.join(root, macControllerBundle)
  const link = path.join(runtime, "bin/mac-controller")
  const source = await Bun.file(path.join(import.meta.dirname, "custom-mac-controller.c")).text()
  const digest = createHash("sha256").update(source).update(infoPlist()).digest("hex")
  const stamp = path.join(root, "source.sha256")
  const installed = await Bun.file(stamp)
    .text()
    .catch(() => "")
  // Programs by name: `mac` rewrites every argument starting with `/` (except `/Users`) as a Linux path.
  if (
    installed.trim() === digest &&
    (await Bun.file(path.join(link)).exists()) &&
    (await host.mac(["codesign", "--verify", "--strict", app])).code === 0
  )
    return "mac controller unchanged"
  const work = path.join(runtime, `.mac-controller-${randomUUID()}`)
  // `mac` processes run without a umask, and this side's umask may leave files group-writable: modes are explicit.
  await mkdir(work, { mode: 0o700 })
  try {
    const file = path.join(work, "mac-controller.c")
    const built = path.join(work, macControllerBundle)
    const executable = path.join(built, "Contents/MacOS/mac-controller")
    await mkdir(path.dirname(executable), { recursive: true, mode: 0o755 })
    await Bun.write(file, source)
    await Bun.write(path.join(built, "Contents/Info.plist"), infoPlist())
    await run(host.mac, ["clang", "-O2", "-Wall", "-Werror", "-o", executable, file])
    await rm(file)
    await chmod(path.join(built, "Contents/Info.plist"), 0o644)
    await chmod(executable, 0o755)
    for (const directory of [built, path.join(built, "Contents"), path.dirname(executable)])
      await chmod(directory, 0o755)
    await run(host.mac, ["security", "unlock-keychain", "-p", "", keychain])
    const identity = (await run(host.mac, ["security", "find-identity", "-p", "codesigning", keychain])).match(
      new RegExp(`\\b([A-F0-9]{40}) "${signingSubject}"`),
    )?.[1]
    if (!identity) throw new Error(`Signing identity "${signingSubject}" is missing from ${keychain}`)
    await run(host.mac, ["codesign", "--force", "--sign", identity, "--keychain", keychain, built])
    await run(host.mac, ["codesign", "--verify", "--strict", built])
    await mkdir(root, { recursive: true, mode: 0o755 })
    await chmod(root, 0o755)
    const previous = path.join(work, "previous.app")
    await rename(app, previous).catch(() => undefined)
    await rename(built, app)
    await Bun.write(stamp, `${digest}\n`)
    await chmod(stamp, 0o644)
    const pending = path.join(work, "link")
    await symlink(path.relative(path.dirname(link), path.join(app, "Contents/MacOS/mac-controller")), pending)
    await mkdir(path.dirname(link), { recursive: true })
    await rename(pending, link)
    // Before the bundle, the controller was a bare `bin/mac-controller` with this stamp beside it.
    await rm(`${link}.sha256`, { force: true })
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

function infoPlist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundleID}</string>
<key>CFBundleExecutable</key><string>mac-controller</string>
<key>CFBundleName</key><string>OpenCode Custom Controller</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
`
}
