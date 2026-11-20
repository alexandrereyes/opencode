// Reading the Bancada's TOML files (the project's `.bancada.toml`, the machine's `bancada.toml`): every problem is
// collected with where it is, in Portuguese, for whoever wrote the file.

export type Raw = Record<string, unknown>

/** The file as a table, or the parser's message. */
export function toml(text: string): Raw | string {
  try {
    const value: unknown = Bun.TOML.parse(text)
    return isTable(value) ? value : "o arquivo não é uma tabela"
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
}

export function list(value: unknown, at: string, problems: string[]): string[] {
  if (value === undefined) return []
  if (Array.isArray(value) && value.every((item) => typeof item === "string")) return value
  problems.push(`${at}: precisa ser uma lista de textos`)
  return []
}

export function text1(value: unknown, at: string, problems: string[]) {
  if (typeof value === "string") return value
  problems.push(`${at}: precisa ser um texto`)
  return undefined
}

export function table(value: unknown, at: string, problems: string[]) {
  if (value === undefined) return undefined
  if (isTable(value)) return value
  problems.push(`${at}: precisa ser uma tabela`)
  return undefined
}

export function unknownKeys(value: Raw, known: ReadonlySet<string>, at: string, problems: string[]) {
  Object.keys(value)
    .filter((key) => !known.has(key))
    .forEach((key) => problems.push(`${at ? `${at}.` : ""}${key}: chave desconhecida`))
}

export function isTable(value: unknown): value is Raw {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
