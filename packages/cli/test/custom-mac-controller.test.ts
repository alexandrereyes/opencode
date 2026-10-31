import { afterEach, expect, test } from "bun:test"
import { mkdtemp, rm, stat } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { installMacController } from "../script/custom-mac-controller"
import { systemd } from "../script/custom-release"

const directories: string[] = []
const identity = "A".repeat(40)

afterEach(async () => {
  for (const directory of directories.splice(0)) await rm(directory, { recursive: true, force: true })
})

/** The Mac as the Linux machine sees it: `/Users/<user>` mounted, and `mac` answering clang, security and codesign. */
async function fixture(options: { keychain?: boolean; verify?: number } = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "mac-controller-"))
  directories.push(root)
  const home = path.join(root, "Users/u")
  const runtime = path.join(home, ".local/share/opencode-custom-v2")
  const keychain = path.join(runtime, "signing/signing.keychain-db")
  if (options.keychain ?? true) await Bun.write(keychain, "keychain")
  const calls: string[][] = []
  const state = { verify: options.verify ?? 0 }
  const host = {
    home,
    async mac(args: string[]) {
      calls.push(args)
      // Like the real `mac`: an absolute program outside /Users becomes a Linux path the Mac cannot run.
      if (args[0]?.startsWith("/") && !args[0].startsWith("/Users/"))
        return { code: 1, stdout: "", stderr: "posix_spawn: no such file or directory" }
      if (args[0] === "clang") await Bun.write(args[args.indexOf("-o") + 1], "mach-o", { mode: 0o777 })
      if (args[0] === "security" && args[1] === "find-identity")
        return { code: 0, stdout: `  1) ${identity} "OpenCode Custom Local Signing"\n`, stderr: "" }
      if (args[0] === "codesign" && args[1] === "--verify" && args.at(-1) === path.join(runtime, "bin/mac-controller"))
        return { code: state.verify, stdout: "", stderr: state.verify ? "invalid signature" : "" }
      return { code: 0, stdout: "", stderr: "" }
    },
  }
  return { host, calls, state, keychain, target: path.join(runtime, "bin/mac-controller") }
}

test("a Linux activation compiles and signs the Mac controller once, through mac, as local.opencode.custom", async () => {
  const mac = await fixture()
  expect(await installMacController(mac.host)).toBe("mac controller installed")
  expect(await Bun.file(mac.target).text()).toBe("mach-o")
  expect((await stat(mac.target)).mode & 0o777).toBe(0o755)
  expect((await stat(`${mac.target}.sha256`)).mode & 0o777).toBe(0o644)
  expect(mac.calls.map((args) => args[0])).toEqual(["clang", "security", "security", "codesign", "codesign"])
  expect(mac.calls[3]).toEqual(
    expect.arrayContaining(["--sign", identity, "--identifier", "local.opencode.custom", "--keychain", mac.keychain]),
  )
  expect(mac.calls[1]).toEqual(["security", "unlock-keychain", "-p", "", mac.keychain])
  // The work directory is gone; only the controller and its source stamp remain.
  expect(await Array.fromAsync(new Bun.Glob("*").scan(path.dirname(mac.target)))).toEqual(
    expect.arrayContaining(["mac-controller", "mac-controller.sha256"]),
  )
  expect(
    await Array.fromAsync(
      new Bun.Glob(".mac-controller-*").scan({ cwd: path.dirname(path.dirname(mac.target)), onlyFiles: false }),
    ),
  ).toEqual([])

  mac.calls.length = 0
  expect(await installMacController(mac.host)).toBe("mac controller unchanged")
  expect(mac.calls).toEqual([["codesign", "--verify", "--strict", mac.target]])
})

test("the Mac controller is rebuilt when its signature stops verifying, and skipped without the signing keychain", async () => {
  const mac = await fixture()
  await installMacController(mac.host)
  mac.state.verify = 1
  mac.calls.length = 0
  expect(await installMacController(mac.host)).toBe("mac controller installed")
  expect(mac.calls.map((args) => args[0])).toContain("clang")
  const bare = await fixture({ keychain: false })
  expect(await installMacController(bare.host)).toContain("skipped")
  expect(bare.calls).toEqual([])
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
