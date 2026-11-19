// The Bancada process as it really runs, plus full garbage collections: the machine's lock must survive them (prova
// E6). Started through `makeBancadaClient({ command })` instead of `daemon/bin.ts`; once it serves, it writes
// `<folder>/collected` after a first collection and keeps collecting while it lives.
import path from "node:path"
import { BancadaDaemon } from "../../src/bancada/daemon/main"

const state = process.env.OPENCODE_BANCADA_STATE
await BancadaDaemon.main()
Bun.gc(true)
const info: unknown = state
  ? await Bun.file(path.join(state, "bancada.json"))
      .json()
      .catch(() => undefined)
  : undefined
if (state && typeof info === "object" && info !== null && "pid" in info && info.pid === process.pid) {
  await Bun.write(path.join(state, "collected"), String(Date.now()))
  setInterval(() => Bun.gc(true), 200).unref()
}
