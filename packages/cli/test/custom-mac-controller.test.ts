import { afterEach, expect, test } from "bun:test"
import { createHash } from "node:crypto"
import { chmod, mkdtemp, readdir, readlink, rm, stat } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { installMacController, macControllerBundle } from "../script/custom-mac-controller"
import { systemd } from "../script/custom-release"

const directories: string[] = []
const identity = "A".repeat(40)

afterEach(async () => {
  for (const directory of directories.splice(0)) await rm(directory, { recursive: true, force: true })
})

/**
 * The real Mac publisher (`custom-mac-host.py`) against a temporary home, as the Mac runs it through `mac`; clang,
 * security and codesign are fakes on PATH that record each call.
 */
async function fixture(options: { keychain?: boolean } = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "mac-controller-"))
  directories.push(root)
  const home = path.join(root, "Users/u")
  const runtime = path.join(home, ".local/share/opencode-custom-v2")
  const keychain = path.join(runtime, "signing/signing.keychain-db")
  if (options.keychain ?? true) await Bun.write(keychain, "keychain")
  const app = path.join(runtime, "mac-controller", macControllerBundle)
  const bin = path.join(root, "bin")
  const log = path.join(root, "tools.log")
  const fail = path.join(root, "verify-fails")
  const tool = (body: string) => `#!/bin/sh\necho "$(basename "$0") $*" >> ${JSON.stringify(log)}\n${body}\n`
  // Like clang under `mac`, which runs without a umask.
  await Bun.write(
    path.join(bin, "clang"),
    tool('while [ "$1" != "-o" ]; do shift; done; printf mach-o > "$2"; chmod 777 "$2"'),
    { mode: 0o755 },
  )
  await Bun.write(
    path.join(bin, "security"),
    tool(`[ "$1" = find-identity ] && echo '  1) ${identity} "OpenCode Custom Local Signing"'; exit 0`),
    { mode: 0o755 },
  )
  await Bun.write(
    path.join(bin, "codesign"),
    tool(
      `[ "$1" = --verify ] && [ -e ${JSON.stringify(fail)} ] && [ "$3" = ${JSON.stringify(app)} ] && exit 1; exit 0`,
    ),
    { mode: 0o755 },
  )
  for (const name of ["clang", "security", "codesign"]) await chmod(path.join(bin, name), 0o755)
  const calls: { args: string[]; input?: Uint8Array }[] = []
  const host = {
    home,
    async mac(args: string[], input?: Uint8Array) {
      calls.push({ args, input })
      const child = Bun.spawn(args, {
        stdin: input ?? "ignore",
        stdout: "pipe",
        stderr: "pipe",
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
      })
      const [stdout, stderr, code] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ])
      return { code, stdout, stderr }
    },
  }
  const tools = async () =>
    (
      await Bun.file(log)
        .text()
        .catch(() => "")
    )
      .split("\n")
      .filter(Boolean)
  return { host, calls, tools, keychain, runtime, app, fail, log, link: path.join(runtime, "bin/mac-controller") }
}

test("a Linux activation sends the controller source to the Mac publisher, which builds and signs it once", async () => {
  const mac = await fixture()
  // The bare binary of the first version is replaced by the link.
  await Bun.write(mac.link, "old bare controller")
  await Bun.write(`${mac.link}.sha256`, "old stamp")
  expect(await installMacController(mac.host)).toBe("mac controller installed")
  const source = await Bun.file(path.join(import.meta.dir, "../script/custom-mac-controller.c")).bytes()
  expect(mac.calls).toHaveLength(1)
  expect(mac.calls[0]!.args.slice(0, 2)).toEqual(["python3", "-c"])
  expect(mac.calls[0]!.args.slice(3)).toEqual([
    "controller",
    mac.host.home,
    "local.opencode.custom",
    "OpenCode Custom Local Signing",
  ])
  expect(mac.calls[0]!.input).toEqual(source)

  const executable = path.join(mac.app, "Contents/MacOS/mac-controller")
  const plist = await Bun.file(path.join(mac.app, "Contents/Info.plist")).text()
  expect(await Bun.file(executable).text()).toBe("mach-o")
  expect(plist).toContain("<key>CFBundleIdentifier</key><string>local.opencode.custom</string>")
  expect(await readlink(mac.link)).toBe(`../mac-controller/${macControllerBundle}/Contents/MacOS/mac-controller`)
  expect(await Bun.file(`${mac.link}.sha256`).exists()).toBe(false)
  for (const file of [mac.app, path.join(mac.app, "Contents"), path.dirname(executable), executable])
    expect((await stat(file)).mode & 0o777).toBe(0o755)
  expect((await stat(path.join(mac.app, "Contents/Info.plist"))).mode & 0o777).toBe(0o644)
  const stamp = path.join(path.dirname(mac.app), "source.sha256")
  expect((await stat(stamp)).mode & 0o777).toBe(0o644)
  // Same digest as the first (TypeScript) version, so an existing install stays "unchanged".
  expect((await Bun.file(stamp).text()).trim()).toBe(createHash("sha256").update(source).update(plist).digest("hex"))
  // Only the app and its stamp remain; the build directory and the C source are gone.
  expect((await readdir(path.dirname(mac.app))).toSorted()).toEqual([macControllerBundle, "source.sha256"])
  const tools = await mac.tools()
  expect(tools.map((line) => line.split(" ").slice(0, 2).join(" "))).toEqual([
    "clang -O2",
    "security unlock-keychain",
    "security find-identity",
    "codesign --force",
    "codesign --verify",
  ])
  expect(tools[3]).toContain(`--sign ${identity} --keychain ${mac.keychain}`)
  expect(tools[3]).toEndWith(`/${macControllerBundle}`)

  await rm(mac.log)
  expect(await installMacController(mac.host)).toBe("mac controller unchanged")
  expect(await mac.tools()).toEqual([`codesign --verify --strict ${mac.app}`])
})

test("the Mac controller is rebuilt when its signature stops verifying, and skipped without the signing keychain", async () => {
  const mac = await fixture()
  await installMacController(mac.host)
  await Bun.write(mac.fail, "")
  await rm(mac.log)
  expect(await installMacController(mac.host)).toBe("mac controller installed")
  expect((await mac.tools()).some((line) => line.startsWith("clang "))).toBe(true)
  expect(await Bun.file(path.join(mac.app, "Contents/MacOS/mac-controller")).text()).toBe("mach-o")
  const bare = await fixture({ keychain: false })
  expect(await installMacController(bare.host)).toContain("skipped")
  expect(await bare.tools()).toEqual([])
})

test("the Linux service installs the Mac controller after activation", async () => {
  const service = systemd(
    "/runtime",
    {
      run: async () => ({ code: 0, stdout: "", stderr: "" }),
      directory: os.tmpdir(),
      alive: async () => false,
      now: Date.now,
      sleep: async () => {},
    },
    async () => "hub",
    async () => "proxy",
    async () => "controller ok",
  )
  expect(await service.controller!()).toBe("controller ok")
})

const compiler = Bun.which("clang") ?? Bun.which("cc")

test.skipIf(!compiler)(
  "the controller runs the command as its child, with its stdio, exit status and signals",
  async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "mac-controller-run-"))
    directories.push(root)
    const binary = path.join(root, "mac-controller")
    const build = Bun.spawnSync([
      compiler!,
      "-O2",
      "-Wall",
      "-Werror",
      "-o",
      binary,
      path.join(import.meta.dir, "../script/custom-mac-controller.c"),
    ])
    expect(build.stderr.toString()).toBe("")
    expect(build.exitCode).toBe(0)

    const echo = Bun.spawn([binary, "sh", "-c", 'read line; echo "$line $PPID"; exit 3'], {
      stdin: "pipe",
      stdout: "pipe",
    })
    echo.stdin.write("hello\n")
    await echo.stdin.end()
    expect(await echo.exited).toBe(3)
    expect((await new Response(echo.stdout).text()).trim()).toBe(`hello ${echo.pid}`)

    const trapped = Bun.spawn([binary, "sh", "-c", 'trap "exit 7" TERM; echo ready; sleep 30 & wait'], {
      stdout: "pipe",
    })
    const reader = trapped.stdout.getReader()
    expect(new TextDecoder().decode((await reader.read()).value)).toContain("ready")
    trapped.kill("SIGTERM")
    expect(await trapped.exited).toBe(7)

    const missing = Bun.spawnSync([binary, "no-such-command-for-mac-controller"])
    expect(missing.exitCode).toBe(127)
    expect(Bun.spawnSync([binary]).exitCode).toBe(64)
  },
)
