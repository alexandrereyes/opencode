import { expect, test } from "bun:test"
import { Effect, Schema, Stream } from "effect"
import { defaults, prompt, review, type Generate } from "../src/dictation"
import { Dictation } from "../src/dictation/rpc"

const raw = "entao eu testei no back studio e passou"

function fake(reply: Stream.Stream<string, { readonly _tag: string; readonly message: string }>) {
  const calls: Array<Parameters<Generate["textStream"]>[0]> = []
  const generate: Generate = {
    textStream: (input) => {
      calls.push(input)
      return reply
    },
  }
  return { generate, calls }
}

const chunk = (text: string, delay: number) => Stream.fromEffect(Effect.as(Effect.sleep(delay), text))

test("joins the streamed reply and asks Terra Fast low with the transcription and its context", async () => {
  const model = fake(Stream.make("Então eu testei ", "no Mac Studio ", "e passou.\n"))
  const result = await Effect.runPromise(review(model.generate, { text: raw, context: "User: Mac Studio" }))
  expect(result).toEqual({ text: "Então eu testei no Mac Studio e passou.", revised: true })
  expect(model.calls).toHaveLength(1)
  expect(model.calls[0]!.model).toEqual(defaults.model)
  expect(model.calls[0]!.prompt).toContain(`<dictation>\n${raw}\n</dictation>`)
  expect(model.calls[0]!.prompt).toContain("<context>\nUser: Mac Studio\n</context>")
})

test("keeps waiting while deltas keep arriving, even past the idle limit in total", async () => {
  const model = fake(Stream.concat(chunk("Um, ", 30), Stream.concat(chunk("dois, ", 30), chunk("três.", 30))))
  const result = await Effect.runPromise(review(model.generate, { text: raw }, "50 millis"))
  expect(result).toEqual({ text: "Um, dois, três.", revised: true })
})

test("gives the transcription back when the first delta or the next one takes longer than the idle limit", async () => {
  const silent = await Effect.runPromise(review(fake(chunk("Tarde.", 200)).generate, { text: raw }, "50 millis"))
  expect(silent).toEqual({ text: raw, revised: false })
  const stalled = fake(Stream.concat(Stream.make("Começou "), Stream.never))
  expect(await Effect.runPromise(review(stalled.generate, { text: raw }, "50 millis"))).toEqual({
    text: raw,
    revised: false,
  })
})

test("gives the transcription back when the model fails or replies with nothing", async () => {
  const failed = fake(Stream.fail({ _tag: "Generate.ProviderRequestError", message: "Overloaded" }))
  expect(await Effect.runPromise(review(failed.generate, { text: raw }))).toEqual({ text: raw, revised: false })
  const midway = fake(Stream.concat(Stream.make("Então "), Stream.fail({ _tag: "Generate.UnavailableError", message: "x" })))
  expect(await Effect.runPromise(review(midway.generate, { text: raw }))).toEqual({ text: raw, revised: false })
  expect(await Effect.runPromise(review(fake(Stream.make("  \n")).generate, { text: raw }))).toEqual({
    text: raw,
    revised: false,
  })
})

test("leaves the context block out when there is no context", () => {
  expect(prompt({ text: raw })).not.toContain("<context>")
  expect(prompt({ text: raw, context: "  \n" })).not.toContain("<context>")
})

test("keeps the prompt free of any language, place or vocabulary", () => {
  const text = prompt({ text: "{dictation}", context: "{context}" })
    .replace("<dictation>\n{dictation}\n</dictation>", "")
    .replace("<context>\n{context}\n</context>", "")
  expect(text).toMatch(/Never translate/)
  // The only non-ASCII characters would come from vocabulary or examples in another language.
  expect(text).toMatch(/^[\x20-\x7E\n]+$/)
  expect(text.toLowerCase()).not.toMatch(
    /portug|brazil|brasil|english|spanish|inglês|french|german|italian|japanese|chinese|example|e\.g\./,
  )
})

test("validates the RPC input", () => {
  const decode = Schema.decodeUnknownSync(Dictation.ReviewInput)
  expect(() => decode({ text: "" })).toThrow()
  expect(() => decode({ text: "x".repeat(Dictation.maxCharacters + 1) })).toThrow()
  expect(decode({ text: "ok", context: "draft" })).toEqual({ text: "ok", context: "draft" })
})
