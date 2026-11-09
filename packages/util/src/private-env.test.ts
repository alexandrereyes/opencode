import { expect, test } from "bun:test"
import { execFileSync } from "node:child_process"
import { PrivateEnv } from "./private-env.js"

const command = (script: string) => ({ [PrivateEnv.variable]: JSON.stringify(["/bin/sh", "-c", script]) })

test("the launcher's command fills the store without touching the environment children inherit", () => {
  const env: NodeJS.ProcessEnv = command(String.raw`printf 'PRIVATE_ENV_TEST_A\0line 1\nline 2\n\0PRIVATE_ENV_TEST_B\0b\0'`)
  expect(PrivateEnv.load(env)).toEqual({ status: "loaded", names: ["PRIVATE_ENV_TEST_A", "PRIVATE_ENV_TEST_B"] })
  expect(PrivateEnv.get("PRIVATE_ENV_TEST_A")).toBe("line 1\nline 2\n")
  expect(PrivateEnv.get("PRIVATE_ENV_TEST_B")).toBe("b")
  expect(env[PrivateEnv.variable]).toBeUndefined()
  // The registry slot is how separately built plugins read the same store.
  expect((globalThis as { [key: symbol]: unknown })[Symbol.for("opencode.private-env")]).toBeInstanceOf(Map)
  const names = (output: string) => output.split("\n").map((line) => line.split("=")[0])
  for (const output of [Bun.spawnSync(["env"]).stdout.toString(), execFileSync("env", { encoding: "utf8" })])
    expect(names(output).filter((name) => name?.startsWith("PRIVATE_ENV_TEST_"))).toEqual([])
})

test("failures name the cause, never the command's output", () => {
  const cases: [NodeJS.ProcessEnv, PrivateEnv.Result][] = [
    [{}, { status: "none" }],
    [{ [PrivateEnv.variable]: "not json" }, { status: "failed", reason: `${PrivateEnv.variable} is not a JSON array of strings` }],
    [command("printf 'X\\0leak-c0ffee\\0'; exit 69"), { status: "failed", reason: "the command failed (exit 69)" }],
    [command("printf 'X\\0leak-c0ffee'"), { status: "failed", reason: "the output is not NAME\\0value\\0 pairs" }],
    [command("printf 'X-Y\\0leak-c0ffee\\0'"), { status: "failed", reason: "the output names an invalid variable" }],
  ]
  for (const [env, result] of cases) expect(PrivateEnv.load(env)).toEqual(result)
  expect(PrivateEnv.get("X")).toBeUndefined()
})
