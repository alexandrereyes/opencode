import { expect, test } from "bun:test"
import { Schema } from "effect"
import { Snippets } from "../src/snippets/rpc"
import { problem } from "../src/snippets/rules"

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

const item = (id: string, name: string, aliases: string[] = [], project?: string) =>
  Schema.decodeUnknownSync(Snippets.Info)({
    id,
    name,
    description: "",
    aliases,
    content: "Texto",
    ...(project ? { project } : {}),
  })

test("names and aliases take letters with accents, digits, - and _ only", () => {
  expect(problem([], item("a", "revisão_2-pr", ["código", "cr"]))).toBeUndefined()
  for (const name of ["a.b", "a@b", "a$b", "a/b", "ação!"])
    expect(problem([], item("a", name))).toEqual({
      type: "invalid",
      data: { field: "name", reason: "format", value: name },
    })
  expect(problem([], item("a", "revisar", ["ok", "two words"]))).toEqual({
    type: "invalid",
    data: { field: "aliases", reason: "format", value: "two words" },
  })
  // Decomposed accents are letters too.
  expect(problem([], item("a", "revisa\u0303o"))).toBeUndefined()
})

test("an alias may not repeat the snippet's own name or another of its aliases, ignoring case", () => {
  expect(problem([], item("a", "revisar", ["Revisar"]))?.data).toEqual({
    field: "aliases",
    reason: "duplicate",
    value: "Revisar",
  })
  expect(problem([], item("a", "revisar", ["cr", "CR"]))?.data).toEqual({
    field: "aliases",
    reason: "duplicate",
    value: "CR",
  })
})

test("every handle is unique in its scope: names and aliases collide in both directions", () => {
  const catalog = [item("g", "revisar", ["review"]), item("p", "deploy", ["swarm"], "prj_a")]
  expect(problem(catalog, item("n", "REVISAR"))).toEqual({
    type: "conflict",
    data: { name: "REVISAR", field: "name", value: "REVISAR", existing: "revisar" },
  })
  expect(problem(catalog, item("n", "review"))?.data).toEqual({
    name: "review",
    field: "name",
    value: "review",
    existing: "revisar",
  })
  expect(problem(catalog, item("n", "resumo", ["Review"]))?.data).toEqual({
    name: "resumo",
    field: "alias",
    value: "Review",
    existing: "revisar",
  })
  // Scopes are separate: a project snippet may take a global name, and another project's alias is free.
  expect(problem(catalog, item("n", "revisar", ["review"], "prj_a"))).toBeUndefined()
  expect(problem(catalog, item("n", "swarm"))).toBeUndefined()
  expect(problem(catalog, item("n", "swarm", [], "prj_a"))?.type).toBe("conflict")
  // Saving a snippet again (same ID) never collides with itself.
  expect(problem(catalog, item("g", "revisar", ["review", "cr"]))).toBeUndefined()
})

test("the errors keep the old conflict payload valid and add the invalid one", () => {
  expect(Schema.decodeUnknownSync(Snippets.Conflict)({ name: "x" })).toEqual({ name: "x" })
  expect(Object.keys(Snippets.Definition.methods.save.errors)).toEqual(["conflict", "invalid"])
})
