// Tests run from an agent inherit the managed server's environment. With it, every server a test starts would join
// production's unified summary as one more server and leave its test sessions on the "Todos" Live Activity
// (docs/unified-summary.md, Configuration). Tests that need these variables pass their own env explicitly.
for (const name of ["OPENCODE_HUB", "OPENCODE_SUMMARY_HUB", "OPENCODE_SUMMARY_HUB_PASSWORD"]) delete process.env[name]
