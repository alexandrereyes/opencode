// Tests run from an agent inherit the managed server's environment. With it, every server a test starts would join
// production's unified summary as one more server and leave its test sessions on the "Todos" Live Activity
// (docs/unified-summary.md, Configuration). Tests that need these variables pass their own env explicitly.
for (const name of ["OPENCODE_HUB", "OPENCODE_SUMMARY_HUB", "OPENCODE_SUMMARY_HUB_PASSWORD"]) delete process.env[name]

// The Bancada starts one process per machine, in the machine's folder (`~/.local/state/opencode-bancada`), which is
// production's here. Tests turn it on only with a folder of their own (`OPENCODE_BANCADA_STATE`) and their own env.
for (const name of ["OPENCODE_BANCADA_STATE", "OPENCODE_BANCADA_CONFIG", "OPENCODE_BANCADA_SELF"])
  delete process.env[name]
process.env.OPENCODE_BANCADA = "0"
