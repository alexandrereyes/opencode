import { FileStorage } from "../../poc/ui-undo/file-storage.js"

const file = process.argv[2]
if (!file) throw new Error("storage path required")

await new FileStorage(file).set("ui-undo/operation/root", {
  version: 1,
  rootSessionID: "root",
  rootMessageID: "cut",
  phase: "staged",
  participants: [{ sessionID: "child", messageID: "input", pendingIDs: [], files: true, depth: 1 }],
  staged: ["child", "root"],
})
