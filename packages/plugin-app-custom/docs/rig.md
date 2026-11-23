# custom.rig

The rig (`/workspace/Dev/rig`, its README) shares the machines' test devices among the agents; it replaced the Bancada
in production on 2026-11-22. The plugin only shows its queue to the apps (the queue button on the Mac, the queue screen
on the iPhone), as the queue's contract between the rig, this plugin and MyAgents fixes it (2026-11-23).

- **`custom.rig/status`**, input `{}`: runs `rig status --json` (the `rig` on the server's PATH, at most 10 s) and
  answers its JSON as it came, `{ versao: 1, agora, maquinas, pedidos, reservas }`; the plugin neither reads nor checks
  it beyond its being JSON. Without `rig` on the PATH: `unavailable` `{ reason: "missing" }`; when it does not end in
  time, ends with another code or prints something that is not JSON: `unavailable` `{ reason: "failed" }`. The apps
  read it when the queue opens and every few seconds while it is visible; there is no event.
- **Devices.** The rig names its emulators and simulators `rig-…`: the resources hub never offers to shut one down
  (`resources.md`, "Stop").
