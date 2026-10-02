import { mkdir, mkdtemp, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { stripVTControlCharacters } from "node:util"

// These parser contracts keep the shell launcher from reaching native lifecycle
// handlers. Use a harmless paths handler as the execution sentinel, even if an
// Effect upgrade breaks the contract being tested.
export async function verifyParser(binary: string, version: string) {
  await mkdir(path.join(os.tmpdir(), "opencode"), { recursive: true })
  const work = await mkdtemp(path.join(os.tmpdir(), "opencode", "parser-smoke-"))
  const env = {
    HOME: work,
    PATH: "/usr/bin:/bin",
    TMPDIR: os.tmpdir(),
    TERM: "dumb",
    NO_COLOR: "1",
    XDG_CONFIG_HOME: `${work}/config`,
    XDG_DATA_HOME: `${work}/data`,
    XDG_STATE_HOME: `${work}/state`,
    XDG_CACHE_HOME: `${work}/cache`,
    OPENCODE_TEST_HOME: work,
    OPENCODE_CONFIG_DIR: `${work}/config/opencode`,
    OPENCODE_DB: `${work}/database.sqlite`,
    OPENCODE_CONFIG_PROJECT_DISABLE: "1",
    OPENCODE_DISABLE_MODELS_FETCH: "1",
    OPENCODE_DISABLE_AUTOUPDATE: "1",
  }
  const run = async (args: string[]) => {
    const child = Bun.spawn([binary, ...args], {
      cwd: work,
      env,
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
      timeout: 15_000,
    })
    const [code, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ])
    return { code, stdout: stripVTControlCharacters(stdout).trim(), stderr: stripVTControlCharacters(stderr).trim() }
  }
  try {
    const control = await run(["debug", "paths", "home"])
    if (control.code !== 0 || control.stdout !== work)
      throw new Error(`CLI parser smoke: paths sentinel failed: ${JSON.stringify(control)}`)

    const rejected = await run(["--server", "http://127.0.0.1:1", "debug", "paths", "home"])
    if (
      rejected.code !== 1 ||
      !rejected.stderr.includes("Unrecognized flag: --server") ||
      rejected.stdout.includes(control.stdout)
    )
      throw new Error(
        `CLI parser smoke: parent server flag reached an unsupported command: ${JSON.stringify(rejected)}`,
      )

    for (const flag of ["--version=false", "--no-version"]) {
      const result = await run(["debug", "paths", "home", flag])
      if (result.code !== 0 || result.stdout !== `opencode v${version}`)
        throw new Error(`CLI parser smoke: ${flag} did not short-circuit the handler: ${JSON.stringify(result)}`)
    }

    const operands = await run(["--server", "http://127.0.0.1:1", "--", "debug", "paths"])
    if (
      operands.code !== 1 ||
      !operands.stdout.includes("USAGE") ||
      !operands.stderr.includes("Unexpected positional argument") ||
      operands.stdout.includes(control.stdout)
    )
      throw new Error(`CLI parser smoke: -- operands were treated as a command path: ${JSON.stringify(operands)}`)

    for (const args of [
      ["debug", "paths", "home", "--help"],
      ["-h", "debug", "paths", "home"],
    ]) {
      const result = await run(args)
      if (
        result.code !== 0 ||
        !result.stdout.includes("USAGE") ||
        !result.stdout.includes("opencode debug paths") ||
        result.stdout.includes(control.stdout)
      )
        throw new Error(`CLI parser smoke: help did not short-circuit the handler: ${JSON.stringify(result)}`)
    }
    // Put help before the command so the root consumes the global action before
    // descending into a command that may have acquired a shadowing local flag.
    // Include ancestors and filesystem-only routes, which also pass through.
    for (const command of [
      ["mcp"],
      ["mcp", "add"],
      ["mcp", "list"],
      ["mcp", "auth"],
      ["mcp", "logout"],
      ["plugin"],
      ["plugin", "add"],
      ["plugin", "remove"],
      ["plugin", "list"],
      ["plugin", "check"],
      ["plugin", "update"],
      ["debug"],
      ["debug", "paths"],
      ["debug", "agents"],
      ["debug", "config"],
      ["pair"],
      ["service"],
      ["service", "get"],
      ["service", "status"],
    ]) {
      const result = await run(["--help", ...command])
      if (result.code !== 0)
        throw new Error(`CLI parser smoke: could not inspect ${command.join(" ")} flags: ${JSON.stringify(result)}`)
      verifyActionFlags(result.stdout, command.join(" "))
    }
    console.log(
      "CLI parser smoke passed: server flag rejection, version actions, -- operands, help actions, no local action aliases",
    )
  } finally {
    await rm(work, { recursive: true, force: true })
  }
}

export function verifyActionFlags(help: string, command: string) {
  const sections = help.split(/(?=^[A-Z][A-Z ]*$)/m)
  if (
    !sections.some((section) => section.startsWith("USAGE\n")) ||
    !sections.some((section) => section.startsWith("GLOBAL FLAGS\n"))
  )
    throw new Error(`CLI parser smoke: unrecognized help sections for ${command}`)
  const shadow = sections
    .filter((section) => !section.startsWith("GLOBAL FLAGS\n"))
    .flatMap((section) => section.split("\n"))
    .map((line) => line.trim().split(/\s{2,}/)[0])
    .find((flags) => flags.startsWith("-") && /(?:^|[\s,])(?:--help|-h|--version|-v)(?=[\s,=]|$)/.test(flags))
  if (shadow) throw new Error(`CLI parser smoke: ${command} has a local help/version flag: ${shadow}`)
}
