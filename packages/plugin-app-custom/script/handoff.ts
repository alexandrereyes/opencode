import { PtyHandoff } from "@opencode/client/pty-handoff"

const file = process.argv[2]
if (!file) throw new Error("Expected a service registration path")
// Finite launcher helper: native handoff validation/expiry, not process supervision.
const env = await PtyHandoff.environment(file)
if (env.OPENCODE_PTY_HANDOFF) process.stdout.write(env.OPENCODE_PTY_HANDOFF)
