import { Database } from "bun:sqlite"
import { OpenCode } from "@opencode/client"
import { Schema } from "effect"
import { LegacyAssignment } from "./index.js"
import { UiUndoRpc } from "./rpc.js"

export function readLegacyAssignments(database: string) {
  const connection = new Database(database, { readonly: true })
  try {
    const rows = connection
      .query(
        `SELECT
        input_id AS inputID,
        parent_session_id AS parentSessionID,
        child_session_id AS childSessionID,
        seq AS assignedSeq,
        message_id AS messageID,
        tool_call_id AS toolCallID
      FROM session_causal
      ORDER BY parent_session_id, seq, input_id`,
      )
      .all()
    return Schema.decodeUnknownSync(Schema.Array(LegacyAssignment))(rows)
  } finally {
    connection.close()
  }
}

if (import.meta.main) {
  const [database, baseUrl, password, directory] = process.argv.slice(2)
  if (!database || !baseUrl || !password || !directory)
    throw new Error("usage: bun legacy-migrate.ts <legacy.db> <url> <password> <location-directory>")
  const client = OpenCode.make({
    baseUrl,
    headers: { authorization: `Basic ${btoa(`opencode:${password}`)}` },
  })
  const result = await client
    .rpc(UiUndoRpc)
    .importLegacy({ rows: readLegacyAssignments(database) }, { location: { directory } })
  console.log(JSON.stringify(result))
}
