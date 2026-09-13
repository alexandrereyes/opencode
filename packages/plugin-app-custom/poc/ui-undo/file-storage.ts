import { mkdir, rename } from "node:fs/promises"
import path from "node:path"
import { Schema } from "effect"
import type { CaptureObservation, LegacyAssignment, Operation, Provenance, Storage } from "./index.js"

const Document = Schema.Record(Schema.String, Schema.Json)

/** Test-only durable adapter. Production integration would use `ctx.storage`. */
export class FileStorage implements Storage {
  constructor(private readonly file: string) {}

  async get(key: string) {
    return (await this.read())[key]
  }

  async set(
    key: string,
    value:
      | Operation
      | Provenance
      | CaptureObservation
      | LegacyAssignment
      | { readonly version: 1; readonly parentSessionID: string }
      | { readonly version: 1; readonly rows: number },
  ) {
    await this.write({ ...(await this.read()), [key]: value })
  }

  async remove(key: string) {
    const values = await this.read()
    await this.write(Object.fromEntries(Object.entries(values).filter(([entry]) => entry !== key)))
  }

  async scan(input: { prefix: string; after?: string; limit?: number }) {
    const values = await this.read()
    const keys = Object.keys(values)
      .filter((key) => key.startsWith(input.prefix) && (!input.after || key > input.after))
      .sort()
    const page = keys.slice(0, input.limit ?? 100)
    return {
      entries: page.map((key) => ({ key, value: values[key] })),
      next: keys.length > page.length ? page.at(-1) : undefined,
    }
  }

  private async read() {
    const file = Bun.file(this.file)
    if (!(await file.exists())) return {}
    return Schema.decodeUnknownSync(Schema.fromJsonString(Document))(await file.text())
  }

  private async write(value: Schema.Schema.Type<typeof Document>) {
    await mkdir(path.dirname(this.file), { recursive: true })
    const temporary = `${this.file}.${crypto.randomUUID()}.tmp`
    await Bun.write(temporary, JSON.stringify(value))
    await rename(temporary, this.file)
  }
}
