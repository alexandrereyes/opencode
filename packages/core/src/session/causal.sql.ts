import { index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core"
import type { SessionMessage } from "./message.js"
import type { SessionSchema } from "./schema.js"
import { SessionTable } from "./sql.js"

export const SessionCausalTable = sqliteTable(
  "session_causal",
  {
    input_id: text().$type<SessionMessage.ID>().primaryKey(),
    parent_session_id: text()
      .$type<SessionSchema.ID>()
      .notNull()
      .references(() => SessionTable.id, { onDelete: "cascade" }),
    child_session_id: text()
      .$type<SessionSchema.ID>()
      .notNull()
      .references(() => SessionTable.id, { onDelete: "cascade" }),
    seq: integer().notNull(),
    message_id: text().$type<SessionMessage.ID>().notNull(),
    tool_call_id: text().notNull(),
  },
  (table) => [
    index("session_causal_parent_seq_idx").on(table.parent_session_id, table.seq),
    index("session_causal_child_idx").on(table.child_session_id),
  ],
)
