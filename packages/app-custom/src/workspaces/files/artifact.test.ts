import { expect, test } from "bun:test"
import { artifactKind, fileContentFromBytes, MAX_MEDIA_BYTES, parseDelimited, resolveArtifactPath } from "./artifact"
import { createPathHelpers } from "./path"

test("binary media retains bytes and oversized or unknown binaries remain placeholders", () => {
  const bytes = new Uint8Array([0, 255, 127, 13])
  const image = fileContentFromBytes("report.PNG", bytes)
  expect(image).toMatchObject({ type: "binary", encoding: "base64", mimeType: "image/png" })
  expect(Uint8Array.from(atob(image.content), (char) => char.charCodeAt(0))).toEqual(bytes)
  expect(fileContentFromBytes("data.bin", bytes)).toEqual({ type: "binary", content: "", size: 4 })
  expect(fileContentFromBytes("large.mp4", new Uint8Array(MAX_MEDIA_BYTES + 1))).toEqual({
    type: "binary",
    content: "",
    size: MAX_MEDIA_BYTES + 1,
  })
})

test.each([
  ["report.html", "html"],
  ["guide.md", "markdown"],
  ["chart.svg", "svg"],
  ["data.csv", "table"],
  ["demo.mmd", "mermaid"],
  ["report.pdf", "pdf"],
  ["font.woff2", "font"],
  ["app.ts", "text"],
])("classifies %s", (path, kind) => expect(artifactKind(path)).toBe(kind))

test("resolves nested references and preserves paths outside the workspace", () => {
  const paths = createPathHelpers(() => "/work/project")
  expect(resolveArtifactPath("docs/reports", "../images/chart.svg")).toBe("docs/images/chart.svg")
  expect(resolveArtifactPath("docs", "../../shared/report.pdf")).toBeUndefined()
  expect(resolveArtifactPath("/work/project/docs", "../../shared/report.pdf")).toBe("/work/shared/report.pdf")
  expect(paths.normalize("/work/project/docs/report.md")).toBe("docs/report.md")
  expect(paths.pathFromTab(paths.tab("/tmp/report.pdf"))).toBe("/tmp/report.pdf")
  expect(paths.normalize("file:///C:/reports/demo.pdf")).toBe("C:/reports/demo.pdf")
})

test("parses quoted delimited rows, pads columns and counts truncated records", () => {
  expect(parseDelimited('name,value\n"a,b","line\nline"\n"say ""hi""",2,extra', ",", 2)).toEqual({
    rows: [
      ["name", "value"],
      ["a,b", "line\nline"],
    ],
    total: 3,
    columns: 2,
  })
  expect(parseDelimited("a\tb\nx\ty\tz", "\t").columns).toBe(3)
})
