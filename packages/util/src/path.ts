export function getFilename(path: string | undefined) {
  if (!path) return ""
  const trimmed = path.replace(/[/\\]+$/, "")
  const index = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"))
  return trimmed.slice(index + 1)
}

export function getDirectory(path: string | undefined) {
  if (!path) return ""
  const trimmed = path.replace(/[/\\]+$/, "")
  const parts = trimmed.split(/[/\\]/)
  return parts.slice(0, parts.length - 1).join("/") + "/"
}

export function getFilenameTruncated(path: string | undefined, maxLength = 20) {
  const filename = getFilename(path)
  if (filename.length <= maxLength) return filename
  const lastDot = filename.lastIndexOf(".")
  const extension = lastDot <= 0 ? "" : filename.slice(lastDot)
  const available = maxLength - extension.length - 1
  if (available <= 0) return filename.slice(0, maxLength - 1) + "…"
  return filename.slice(0, available) + "…" + extension
}

export function truncateMiddle(text: string, maxLength = 20) {
  if (text.length <= maxLength) return text
  const available = maxLength - 1
  const start = Math.ceil(available / 2)
  const end = Math.floor(available / 2)
  return text.slice(0, start) + "…" + text.slice(-end)
}

const MAX_LINE_NUMBER = 1_000_000

const lineHashPattern = /^#L(\d+)(?:C\d+)?(?:-L?(\d+)(?:C\d+)?)?$/i

const lineHashSuffixPattern = /^(.*?)#L(\d+)(?:C\d+)?(?:-L?(\d+)(?:C\d+)?)?$/i

const lineColonSuffixPattern = /^(.*?):(\d+)(?::\d+)?(?:-(\d+)(?::\d+)?)?:?$/

function toLineRange(first: number, second: number) {
  if (
    !Number.isSafeInteger(first) ||
    !Number.isSafeInteger(second) ||
    first < 1 ||
    second < 1 ||
    first > MAX_LINE_NUMBER ||
    second > MAX_LINE_NUMBER
  ) {
    return undefined
  }

  return {
    start: Math.min(first, second),
    end: Math.max(first, second),
  }
}

export function isLineRangeHash(hash: string) {
  return lineHashPattern.test(hash)
}

export function parsePathLineSuffix(input: string) {
  const hashMatch = input.match(lineHashSuffixPattern)

  if (hashMatch) {
    const first = Number(hashMatch[2])
    const second = hashMatch[3] ? Number(hashMatch[3]) : first

    return {
      path: hashMatch[1] ?? "",
      selection: toLineRange(first, second),
    }
  }

  const colonMatch = input.match(lineColonSuffixPattern)

  if (colonMatch && !/^[a-z]:?$/i.test(colonMatch[1] ?? "")) {
    const first = Number(colonMatch[2])
    const second = colonMatch[3] ? Number(colonMatch[3]) : first

    return {
      path: colonMatch[1] ?? "",
      selection: toLineRange(first, second),
    }
  }

  return { path: input, selection: undefined }
}
