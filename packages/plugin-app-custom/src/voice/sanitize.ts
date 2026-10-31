/**
 * Text from the voice service made safe to log: no control characters, quoted spans longer than 32 characters
 * (which could echo appended speech) replaced by `"…"`, whitespace collapsed, at most `max` characters. The apps'
 * `VoiceDiagnosticText.sanitize` follows the same rules.
 */
export function sanitize(value: string, max: number) {
  const text = value
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
    .replace(/"[^"]{33,}"|“[^”]{33,}”|'[^']{33,}'/g, '"…"')
    .replace(/\s+/g, " ")
    .trim()
  const characters = Array.from(text)
  return characters.length > max ? characters.slice(0, max - 1).join("") + "…" : text
}
