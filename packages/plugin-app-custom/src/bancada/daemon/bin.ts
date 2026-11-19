import { BancadaDaemon } from "./main.js"

// Source and `dist` entry; the release bundle runs the same `main` through `custom-plugin.ts`.
await BancadaDaemon.main()
