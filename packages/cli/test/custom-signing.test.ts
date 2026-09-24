import { afterEach, expect, test } from "bun:test"
import { mkdtemp, readlink, rm, stat } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { command } from "../script/custom-release"
import { bundle, bundleRelease } from "../script/custom-signing"

const homes: string[] = []

afterEach(async () => {
  await Promise.all(homes.splice(0).map((home) => rm(home, { recursive: true, force: true })))
})

test.skipIf(process.platform !== "darwin")(
  "releases at different paths share one persistent designated requirement",
  async () => {
    const home = await mkdtemp(path.join(os.tmpdir(), "opencode-custom-signing-"))
    homes.push(home)
    const searchList = await command(["/usr/bin/security", "list-keychains", "-d", "user"])
    await bundleRelease(home, `${home}/releases/first`, "/usr/bin/true")
    await bundleRelease(home, `${home}/releases/second`, "/usr/bin/false")

    const requirement = (release: string) =>
      command(["/usr/bin/codesign", "-d", "-r-", `${home}/releases/${release}/${bundle}`]).then(
        (output) => output.split("\n").find((line) => line.startsWith("designated =>")) ?? "",
      )
    const first = await requirement("first")
    expect(first).toMatch(/^designated => identifier "local\.opencode\.custom" and certificate leaf = H"[a-f0-9]{40}"$/)
    expect(await requirement("second")).toBe(first)
    expect(await readlink(`${home}/releases/first/bin/opencode`)).toBe(`../${bundle}/Contents/MacOS/opencode`)
    expect(await Bun.spawn([`${home}/releases/first/bin/opencode`]).exited).toBe(0)
    expect((await stat(`${home}/signing`)).mode & 0o777).toBe(0o700)
    expect((await stat(`${home}/signing/signing.keychain-db`)).mode & 0o777).toBe(0o600)
    expect(await command(["/usr/bin/security", "list-keychains", "-d", "user"])).toBe(searchList)
  },
)
