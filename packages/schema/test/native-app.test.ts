import { expect, test } from "bun:test"
import { Schema } from "effect"
import { NativeApp } from "../src/native-app.js"
import { AbsolutePath } from "../src/schema.js"

test("native app requests accept known apps and omit unspecified reveal", () => {
  const input = { app: "rider" as const, path: AbsolutePath.make("/worktree with spaces"), reveal: undefined }
  expect(Schema.encodeSync(NativeApp.OpenInput)(input)).toEqual({ app: "rider", path: input.path })
  expect(() => Schema.decodeUnknownSync(NativeApp.OpenInput)({ app: "sh", path: "/project" })).toThrow()
})
