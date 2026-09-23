import type { FileContent } from "@/runtime/server/types"

const formats = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  avif: "image/avif",
  bmp: "image/bmp",
  ico: "image/x-icon",
  tif: "image/tiff",
  tiff: "image/tiff",
  heic: "image/heic",
  svg: "image/svg+xml",
  mp3: "audio/mpeg",
  wav: "audio/wav",
  ogg: "audio/ogg",
  oga: "audio/ogg",
  m4a: "audio/mp4",
  aac: "audio/aac",
  flac: "audio/flac",
  opus: "audio/ogg",
  weba: "audio/webm",
  mp4: "video/mp4",
  m4v: "video/mp4",
  webm: "video/webm",
  mov: "video/quicktime",
  ogv: "video/ogg",
  mkv: "video/x-matroska",
  pdf: "application/pdf",
  html: "text/html",
  htm: "text/html",
  md: "text/markdown",
  markdown: "text/markdown",
  mdx: "text/markdown",
  mmd: "text/vnd.mermaid",
  mermaid: "text/vnd.mermaid",
  csv: "text/csv",
  tsv: "text/tab-separated-values",
  ttf: "font/ttf",
  otf: "font/otf",
  woff: "font/woff",
  woff2: "font/woff2",
}
const mimes = new Map(Object.entries(formats))
export function artifactMime(path: string) {
  return mimes.get(path.split(/[\\/]/).pop()?.split(".").slice(1).pop()?.toLowerCase() ?? "")
}

export function artifactKind(path: string) {
  const mime = artifactMime(path)
  if (!mime) return "text"
  if (mime === "image/svg+xml") return "svg"
  if (mime === "application/pdf") return "pdf"
  if (mime === "text/html") return "html"
  if (mime === "text/markdown") return "markdown"
  if (mime === "text/vnd.mermaid") return "mermaid"
  if (mime === "text/csv" || mime === "text/tab-separated-values") return "table"
  if (mime.startsWith("image/")) return "image"
  if (mime.startsWith("audio/")) return "audio"
  if (mime.startsWith("font/")) return "font"
  return "video"
}

export const MAX_MEDIA_BYTES = 25 * 1024 * 1024
export function fileContentFromBytes(path: string, bytes: Uint8Array): FileContent {
  const kind = artifactKind(path)
  const mimeType = artifactMime(path)
  if (["image", "audio", "video", "pdf", "font"].includes(kind)) {
    if (bytes.length > MAX_MEDIA_BYTES) return { type: "binary", content: "", size: bytes.length }
    const parts: string[] = []
    for (let index = 0; index < bytes.length; index += 0x8000) {
      parts.push(String.fromCharCode(...bytes.subarray(index, index + 0x8000)))
    }
    return { type: "binary", content: btoa(parts.join("")), encoding: "base64", mimeType }
  }
  if (kind === "text" && bytes.subarray(0, 8192).includes(0)) return { type: "binary", content: "", size: bytes.length }
  return { type: "text", content: new TextDecoder().decode(bytes), mimeType }
}

export function blobUrlFromContent(content: FileContent) {
  const type = content.mimeType ?? "application/octet-stream"
  if (content.encoding !== "base64") return URL.createObjectURL(new Blob([content.content], { type }))
  return URL.createObjectURL(new Blob([Uint8Array.from(atob(content.content), (char) => char.charCodeAt(0))], { type }))
}

export function resolveArtifactPath(base: string, href: string) {
  const target = href.replaceAll("\\", "/")
  if (target.startsWith("/")) return undefined
  const dir = base.replaceAll("\\", "/")
  const segments = dir.split("/").filter(Boolean)
  for (const segment of target.split("/")) {
    if (!segment || segment === ".") continue
    if (segment !== "..") {
      segments.push(segment)
      continue
    }
    if (!segments.length) return undefined
    segments.pop()
  }
  return `${dir.startsWith("/") ? "/" : ""}${segments.join("/")}`
}

export function parseDelimited(text: string, delimiter: string, limit = 1000) {
  const rows: string[][] = []
  let row: string[] = []
  let field = ""
  let quoted = false
  let total = 0
  const endRow = () => {
    row.push(field)
    field = ""
    if (row.length !== 1 || row[0] !== "") {
      total++
      if (rows.length < limit) rows.push(row)
    }
    row = []
  }
  for (let index = 0; index < text.length; index++) {
    const char = text[index]!
    if (quoted) {
      if (char !== '"') {
        field += char
        continue
      }
      if (text[index + 1] === '"') {
        field += '"'
        index++
        continue
      }
      quoted = false
      continue
    }
    if (char === '"' && field === "") {
      quoted = true
      continue
    }
    if (char === delimiter) {
      row.push(field)
      field = ""
      continue
    }
    if (char === "\r") continue
    if (char === "\n") {
      endRow()
      continue
    }
    field += char
  }
  if (field !== "" || row.length) endRow()
  return { rows, total, columns: rows.reduce((max, current) => Math.max(max, current.length), 0) }
}
