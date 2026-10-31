import os from "node:os"
import path from "node:path"
import { macPublish, onMac } from "./custom-release"
import { bundleID, signingSubject } from "./custom-signing"

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
 * The C source travels on stdin to the Mac publisher (`custom-mac-host.py controller`), which builds, signs and swaps
 * the app on the Mac: Linux never opens the shared mount. Rebuilt when the source or `Info.plist` changes or the
 * installed signature no longer verifies; skipped without the signing keychain. It grants nothing a process of this
 * user lacks: the signing keychain belongs to this user, with an empty password.
 */
export async function installMacController(
  host: { home: string; mac: typeof onMac } = { home: `/Users/${os.userInfo().username}`, mac: onMac },
) {
  const source = await Bun.file(path.join(import.meta.dirname, "custom-mac-controller.c")).bytes()
  return macPublish(host, "controller", [bundleID, signingSubject], source)
}
