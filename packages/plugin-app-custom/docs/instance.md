# Server identity (`custom.instance`)

The native apps (`MyAgents`) show the sessions of several servers together. Each server says who it is, so that:

- the iPhone and the Mac recognize the **same** server saved under different addresses (the Mac sees itself as
  `127.0.0.1:4096`; the iPhone reaches it through Cloudflare);
- the apps adopt the **hub** by themselves: the server that writes the single Live Activity. The deployment declares
  it, as it already names the server with `OPENCODE_HOST_NAME`.

## Contract

`custom.instance` / `get`, input `{}`, output:

```json
{
  "version": 1,
  "instanceID": "3f0c1f4e-6c0b-4a57-9d55-0a4f3b1c9e21",
  "name": "Linux BRS",
  "hub": true
}
```

- `version`: the contract's number, `1`.
- `instanceID`: a random UUID made on the first read and kept in the plugin's storage (key `instance:id`). It
  survives restarts and updates and never changes by itself; it follows the database, so a server restored from
  another's database answers with that server's ID.
- `name`: the name the Live Activity card shows (`hostName` of `live-activity`): `OPENCODE_HOST_NAME` when the
  deployment sets it (trimmed, at most 40 characters), else macOS's ComputerName, else the host name.
- `hub`: `true` only when the server's environment has `OPENCODE_HUB=1`; absent or any other value is `false`. It is
  read on every call, and the environment only changes with a restart.

Over HTTP, as every plugin RPC: `POST /api/rpc/custom.instance/get` with the body `{"input":{}}`; the answer comes
as `{"output":{…}}`. The identity is the server's, the same from every Location. A server whose plugin predates this
module answers `rpc.unavailable` (the core's answer for an RPC ID nobody registered; `rpc.method_not_found` is for an
unknown method of a registered one), which the apps treat as a server without identity or declared hub.

## Deployment

| Variable | Value | Effect |
| --- | --- | --- |
| `OPENCODE_HUB` | `1` | `hub: true`. Set it on one server only (the Linux BRS compose, next to `OPENCODE_HOST_NAME`) |
| `OPENCODE_HOST_NAME` | text | `name` |

The plugin does not check that only one server declares itself the hub; which one to follow when two do is the
apps' decision.

## Tests

`test/instance.test.ts`: the contract; one ID per storage (two reads, two plugin instances asking at once, a restart
over the same storage, another storage); `hub` for each value of `OPENCODE_HUB`; `name` from `OPENCODE_HOST_NAME`.
