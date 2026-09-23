import { describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Schema } from "effect"
import { createDirectory } from "../src/directories"
import { Directories } from "../src/directories/rpc"

describe("directories", () => {
  test("publishes the browser-safe RPC contract", () => {
    expect(Directories.Definition.id).toBe("custom.directories")
    expect(Object.keys(Directories.Definition.methods)).toEqual(["home", "create"])
    expect(Object.keys(Directories.Definition.methods.create.errors)).toEqual(["create_failed"])
    expect(() => Schema.decodeUnknownSync(Directories.CreateFailure)("unknown")).toThrow()
  })

  test("creates only the final directory segment", async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-directories-"))
    try {
      const target = path.join(root, "new project")
      expect(await createDirectory(target + "/")).toEqual({ path: target })
      expect((await fs.stat(target)).isDirectory()).toBe(true)
      expect(await createDirectory(target)).toBe("exists")
      expect(await createDirectory(path.join(root, "missing", "child"))).toBe("missing-parent")
      expect(await fs.readdir(root)).toEqual(["new project"])
      await fs.writeFile(path.join(root, "file"), "")
      expect(await createDirectory(path.join(root, "file", "child"))).toBe("invalid-path")
    } finally {
      await fs.rm(root, { recursive: true })
    }
  })

  test("rejects relative and root paths", async () => {
    expect(await createDirectory("relative/project")).toBe("invalid-path")
    expect(await createDirectory("/")).toBe("invalid-path")
  })
})
