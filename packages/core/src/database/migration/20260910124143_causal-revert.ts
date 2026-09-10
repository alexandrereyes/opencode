import { Effect } from "effect"
import type { DatabaseMigration } from "../migration.js"

const migration: DatabaseMigration.Migration = {
  id: "20260910124143_causal-revert",
  up(tx) {
    return Effect.gen(function* () {
      yield* tx.run(`
        CREATE TABLE \`session_causal\` (
          \`input_id\` text PRIMARY KEY,
          \`parent_session_id\` text NOT NULL,
          \`child_session_id\` text NOT NULL,
          \`seq\` integer NOT NULL,
          \`message_id\` text NOT NULL,
          \`tool_call_id\` text NOT NULL,
          CONSTRAINT \`fk_session_causal_parent_session_id_session_v2_id_fk\` FOREIGN KEY (\`parent_session_id\`) REFERENCES \`session_v2\`(\`id\`) ON DELETE CASCADE,
          CONSTRAINT \`fk_session_causal_child_session_id_session_v2_id_fk\` FOREIGN KEY (\`child_session_id\`) REFERENCES \`session_v2\`(\`id\`) ON DELETE CASCADE
        );
      `)
      yield* tx.run(
        `CREATE INDEX \`session_causal_parent_seq_idx\` ON \`session_causal\` (\`parent_session_id\`,\`seq\`);`,
      )
      yield* tx.run(`CREATE INDEX \`session_causal_child_idx\` ON \`session_causal\` (\`child_session_id\`);`)
    })
  },
}

export default migration
