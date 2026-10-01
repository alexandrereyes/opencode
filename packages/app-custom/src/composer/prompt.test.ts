import { describe, expect, test } from "bun:test"
import type { SessionMessageUser } from "@opencode/client/promise"
import { extractPromptComments, extractPromptFromMessage } from "./prompt"
import { restoreChatQuotes } from "./chat-quote"

describe("extractPromptFromMessage", () => {
  test("restores multiple uploaded attachments", () => {
    const message = {
      id: "msg_1",
      type: "user",
      text: "check these",
      files: [
        { data: "AAA", mime: "image/png", source: { type: "inline" }, name: "a.png" },
        { data: "BBB", mime: "application/pdf", source: { type: "inline" }, name: "b.pdf" },
      ],
      time: { created: 1 },
    } satisfies SessionMessageUser

    const result = extractPromptFromMessage(message)

    expect(result).toHaveLength(3)
    expect(result[0]).toMatchObject({ type: "text", content: "check these" })
    expect(result.slice(1)).toMatchObject([
      {
        type: "image",
        filename: "a.png",
        mime: "image/png",
        blob: expect.objectContaining({ id: expect.any(String) }),
      },
      {
        type: "image",
        filename: "b.pdf",
        mime: "application/pdf",
        blob: expect.objectContaining({ id: expect.any(String) }),
      },
    ])
  })

  test("leaves trailing quote comment images to their quotes", () => {
    const quote = {
      id: "q1",
      messageID: "msg_a",
      partID: "prt_a",
      text: "earlier",
      comment: "",
      commentPrompt: [{ type: "image", id: "pic", filename: "pic.png", mime: "image/png", blob: { id: "hash" } }],
    }
    const message = {
      id: "msg_1",
      type: "user",
      text: "check these",
      metadata: { displayText: "check these", comments: [], quotes: [quote] },
      files: [
        { data: "AAA", mime: "image/png", source: { type: "inline" }, name: "a.png" },
        { data: "cGlj", mime: "image/png", source: { type: "inline" }, name: "pic.png" },
      ],
      time: { created: 1 },
    } satisfies SessionMessageUser

    expect(extractPromptFromMessage(message).slice(1)).toMatchObject([{ type: "image", filename: "a.png" }])
    expect(restoreChatQuotes(message.metadata.quotes, message.files).quotes[0]?.commentPrompt).toEqual([
      {
        type: "image",
        id: "pic",
        filename: "pic.png",
        mime: "image/png",
        blob: { id: "data:image/png;base64,cGlj", url: "data:image/png;base64,cGlj" },
      },
    ])
  })

  test("restores optimistic data URLs and review comments", () => {
    const message = {
      id: "msg_1",
      type: "user",
      text: "model text",
      metadata: {
        displayText: "visible text",
        comments: [
          {
            path: "src/app.ts",
            comment: "check this",
            selection: { startLine: 2, startChar: 0, endLine: 2, endChar: 4 },
            origin: "review",
          },
        ],
      },
      files: [
        {
          data: "",
          mime: "image/png",
          source: { type: "uri", uri: "data:image/png;base64,AAA" },
          name: "a.png",
        },
      ],
      time: { created: 1 },
    } satisfies SessionMessageUser

    expect(extractPromptFromMessage(message)).toMatchObject([
      { type: "text", content: "visible text" },
      { type: "image", filename: "a.png", mime: "image/png" },
    ])
    expect(extractPromptComments(message)).toMatchObject([
      { path: "src/app.ts", comment: "check this", origin: "review" },
    ])
  })

  test("keeps the directory of a file mention without an at-sign", () => {
    const message = {
      id: "msg_1",
      type: "user",
      text: "inspect src/client.ts",
      files: [
        {
          data: "",
          mime: "text/plain",
          source: { type: "uri", uri: "file:///repo/src/client.ts" },
          name: "client.ts",
          mention: { text: "src/client.ts", start: 8, end: 21 },
        },
      ],
      time: { created: 1 },
    } satisfies SessionMessageUser

    expect(extractPromptFromMessage(message)).toMatchObject([
      { type: "text", content: "inspect " },
      { type: "file", content: "src/client.ts", path: "src/client.ts" },
    ])
  })

  test("uses model text when presentation metadata is incomplete", () => {
    const message = {
      id: "msg_1",
      type: "user",
      text: "model text",
      metadata: { displayText: "partial display text" },
      time: { created: 1 },
    } satisfies SessionMessageUser

    expect(extractPromptFromMessage(message)[0]).toMatchObject({ type: "text", content: "model text" })
  })

  test("restores skill mentions as structured Composer parts", () => {
    const message = {
      id: "msg_1",
      type: "user",
      text: "Use $review",
      skills: [{ id: "review", name: "Review", mention: { text: "$review", start: 4, end: 11 } }],
      time: { created: 1 },
    } satisfies SessionMessageUser

    expect(extractPromptFromMessage(message)).toMatchObject([
      { type: "text", content: "Use " },
      {
        type: "skill",
        id: "review",
        name: "Review",
        content: "$review",
      },
    ])
  })
})
