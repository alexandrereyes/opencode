import { chmod, copyFile, mkdir, rename, rm, symlink } from "node:fs/promises"
import { randomUUID } from "node:crypto"
import path from "node:path"
import { command } from "./custom-release"

// macOS privacy grants (TCC) follow the responsible process: the launchd-owned server.
// Standalone executables are keyed by path and ad-hoc signatures by cdhash, so every
// release looked like a new program. A fixed bundle identifier plus a persistent local
// certificate gives all releases the same designated requirement.
export const bundle = "OpenCode Custom.app"
export const bundleID = "local.opencode.custom"
const subject = "OpenCode Custom Local Signing"

export async function bundleRelease(home: string, staging: string, binary: string) {
  const app = path.join(staging, bundle)
  const executable = path.join(app, "Contents/MacOS/opencode")
  await mkdir(path.dirname(executable), { recursive: true })
  await mkdir(path.join(staging, "bin"), { recursive: true })
  await copyFile(binary, executable)
  await chmod(executable, 0o755)
  await Bun.write(path.join(app, "Contents/Info.plist"), infoPlist())
  await symlink(path.join("..", bundle, "Contents/MacOS/opencode"), path.join(staging, "bin/opencode"))
  const signing = await signingIdentity(home)
  await command(["/usr/bin/codesign", "--force", "--sign", signing.identity, "--keychain", signing.keychain, app])
  await command(["/usr/bin/codesign", "--verify", "--strict", app])
}

export async function signingIdentity(home: string) {
  const directory = path.join(home, "signing")
  const keychain = path.join(directory, "signing.keychain-db")
  if (!(await Bun.file(keychain).exists())) await createSigning(home, directory)
  // The key is protected by the private directory; an empty keychain password keeps
  // unattended updates free of Keychain prompts.
  await command(["/usr/bin/security", "unlock-keychain", "-p", "", keychain])
  const identity = (await command(["/usr/bin/security", "find-identity", "-p", "codesigning", keychain])).match(
    new RegExp(`\\b([A-F0-9]{40}) "${subject}"`),
  )?.[1]
  if (!identity) throw new Error(`Signing identity "${subject}" is missing from ${keychain}`)
  return { keychain, identity }
}

async function createSigning(home: string, directory: string) {
  const work = path.join(home, `.signing-${randomUUID()}`)
  await mkdir(work, { mode: 0o700 })
  const keychain = path.join(work, "signing.keychain-db")
  const passphrase = randomUUID()
  // LibreSSL writes PKCS#12 files that `security import` accepts without legacy flags.
  await command(
    [
      "/usr/bin/openssl",
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "36500",
      "-subj",
      `/CN=${subject}`,
      "-addext",
      "basicConstraints=critical,CA:false",
      "-addext",
      "keyUsage=critical,digitalSignature",
      "-addext",
      "extendedKeyUsage=critical,codeSigning",
      "-keyout",
      `${work}/key.pem`,
      "-out",
      `${work}/cert.pem`,
    ],
    work,
  )
  await command(
    [
      "/usr/bin/openssl",
      "pkcs12",
      "-export",
      "-inkey",
      `${work}/key.pem`,
      "-in",
      `${work}/cert.pem`,
      "-out",
      `${work}/identity.p12`,
      "-passout",
      `pass:${passphrase}`,
    ],
    work,
  )
  await command(["/usr/bin/security", "create-keychain", "-p", "", keychain])
  await command([
    "/usr/bin/security",
    "import",
    `${work}/identity.p12`,
    "-k",
    keychain,
    "-P",
    passphrase,
    "-T",
    "/usr/bin/codesign",
  ])
  await command([
    "/usr/bin/security",
    "set-key-partition-list",
    "-S",
    "apple-tool:,apple:,codesign:",
    "-s",
    "-k",
    "",
    keychain,
  ])
  await Promise.all(["key.pem", "cert.pem", "identity.p12"].map((file) => rm(path.join(work, file))))
  await chmod(keychain, 0o600)
  await rename(work, directory)
}

function infoPlist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundleID}</string>
<key>CFBundleExecutable</key><string>opencode</string>
<key>CFBundleName</key><string>OpenCode Custom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
`
}
