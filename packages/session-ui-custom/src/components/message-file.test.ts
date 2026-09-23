import { describe, expect, test } from "bun:test"
import { attached, typeLabel } from "./message-file"

describe("message-file", () => {
  test("distinguishes inline attachments from mentions and file context", () => {
    expect(attached({ mime: "image/png", data: "YQ==", source: { type: "inline" } })).toBe(true)
    expect(
      attached({
        mime: "image/png",
        data: "YQ==",
        source: { type: "inline" },
        mention: { text: "[image.png]", start: 0, end: 11 },
      }),
    ).toBe(false)
    expect(attached({ mime: "text/plain", data: "", source: { type: "uri", uri: "file:///tmp/file.txt" } })).toBe(false)
    expect(attached({ mime: "image/png", data: "", source: { type: "uri", uri: "data:image/png;base64,YQ==" } })).toBe(
      true,
    )
  })
  test("labels attachment types from the basename extension", () => {
    expect(typeLabel("list.md", "text/plain", "File")).toBe("Markdown")
    expect(typeLabel("/repo/src/main.ts", "text/plain", "File")).toBe("TypeScript")
    expect(typeLabel("/tmp/report.pdf", "application/pdf", "File")).toBe("PDF")
    expect(typeLabel("notes.xyz", "text/plain", "File")).toBe("XYZ")
    expect(typeLabel("/home/user/my.project/Makefile", "text/plain", "File")).toBe("File")
    expect(typeLabel(".gitignore", "text/plain", "File")).toBe("File")
    expect(typeLabel("/repo/.env", "text/plain", "File")).toBe("File")
  })
})
