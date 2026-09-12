import { expect, test } from "bun:test"
import { Schema } from "effect"
import { Snippets } from "../src/snippets/rpc"

const snippet = {
  id: "review",
  name: "review",
  description: "Review code",
  aliases: ["audit"],
  content: "Check correctness.",
}

test("preserves the snippet wire contract and omits an absent project", () => {
  expect(Schema.encodeSync(Snippets.Info)(snippet)).toEqual(snippet)
  expect(() => Schema.decodeUnknownSync(Snippets.Info)({ ...snippet, name: "two words" })).toThrow()
  expect(() => Schema.decodeUnknownSync(Snippets.Info)({ ...snippet, name: "#review" })).toThrow()
  expect(() => Schema.decodeUnknownSync(Snippets.Info)({ ...snippet, content: "  " })).toThrow()
  expect(Snippets.Definition.id).toBe("custom.snippets")
  expect(Object.keys(Snippets.Definition.events)).toEqual(["updated"])
})
