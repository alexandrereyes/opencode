# Host meters (`custom.host`)

The Mac app's rail shows three meters of the connected server (`MyAgents`, README "Medidores do servidor"): disk, CPU
and memory. They come from the server and only from it: the app has no local fallback, so a server without this
module, or a part it cannot read, shows no meter (or not that one).

## Contract

`custom.host` / `get`, input `{ parts?: ("cpu" | "memory" | "disk")[] }` (all by default), output:

```json
{
  "name": "Linux BRS",
  "platform": "linux",
  "scope": "machine",
  "cpu": { "percent": 37.4, "cores": 48 },
  "memory": { "used": 23611453440, "total": 405594832896 },
  "disk": { "free": 3758096384000, "total": 4724464025600, "path": "/workspace" },
  "at": 1794517776968
}
```

- `name`: `OPENCODE_HOST_NAME` when the deployment names the server (the Linux BRS compose sets it), else macOS's
  ComputerName (read once per process), else the host name.
- `scope` is always `machine`: the whole machine, never a container's cgroup.
- `cpu`, `memory` and `disk` are each left out when they cannot be read; the call itself does not fail for them.
- The app asks for CPU and memory every 2 s and for the disk every minute, only while its window is visible and the
  app is in front. Nothing is measured between calls.

## How it measures

| Part | Linux (also inside the Linux BRS container) | macOS |
| --- | --- | --- |
| CPU | `/proc/stat`'s first line: busy share since the previous reading (idle + iowait as idle; user through steal as total, guest already in user); cores are its `cpuN` lines | `os.cpus()` times summed (`host_processor_info`) |
| Memory | `/proc/meminfo`: `MemTotal − MemAvailable` (older kernels: free + buffers + cached as available) | `host_statistics64(HOST_VM_INFO64)` through `bun:ffi`, what `vm_stat` calls: anonymous − purgeable + wired + compressor pages, Activity Monitor's "Memory Used"; total from `os.totalmem()`. `vm_stat` (cached 1.5 s) only if the call cannot be made. Never `os.freemem()`, which counts the cache as used |
| Disk | `statfs` of the server's home folder: available (`bavail`) and total blocks | the same (APFS: without the purgeable space Finder adds) |

Inside a Docker container `/proc/stat` and `/proc/meminfo` are the host's (Docker does not namespace them; only lxcfs
would, and the Linux BRS has none), so the meters show the host-6 machine even though the container is limited to
8 CPUs and 8 GiB. The workspace volume lives on the host's own disk (`/dev/sda3`), so `statfs("/workspace")` is the disk
that fills up. No compose change is needed.

CPU needs two readings. One process-wide sample lives in `globalThis.opencodeCustomHostCpu` (the plugin is evaluated
once per Location): each call measures since the previous one; calls closer than 0.5 s share the last value; a first
call, or one after 10 s of silence, reads twice 0.25 s apart. The Mach host port and the `bun:ffi` handle are also kept
once per process (`globalThis.opencodeCustomHostMach`).

## Cost

Measured on the Mac (M-series, 16 cores): memory 0.03 ms (one Mach call), disk 0.03 ms, CPU 0.35 ms (`os.cpus()`); a
first call waits 0.25 s for its second CPU reading. On Linux the three parts are file reads of a few kilobytes. No process
is started per call.

## Checked against the machines (2026-11-12)

- **Mac** (sandbox server on 4191, `custom-sandbox.ts`): memory 99.9 GB of 128 GB, against Activity Monitor's App Memory
  39.04 + Wired 13.62 + Compressed 47.21 = 99.87 GB (its own "Memória Usada" read 101.28 GB, 1.4% above its three
  parts); CPU 36–39% over three calls 2 s apart, `top` 40.8% busy over 2 s; disk 236 GB available of 1,995 GB (Finder
  and the app's former local meter add the purgeable space, some 50 GB more). One call over HTTP: 1.4 ms.
- **Linux BRS** (this module bundled and run once inside `opencode_opencode-svc` with `docker exec`, nothing deployed):
  48 cores; CPU 4.8% against the host's `top` 4.7% busy over the same 2 s; memory 23.12 GB of 405.6 GB against the host's
  `free` total − available 23.10 GB; disk 3,782.8 GB free of 4,719.0 GB, the host's `df /` to the megabyte. A snapshot of
  the three parts: 0.74 ms.

## Tests

`test/host.test.ts`: the contract; `/proc/stat` (cores, idle with iowait, guest left out) and the busy share; `/proc/meminfo`
with and without `MemAvailable`; `vm_stat` and the Memory Used formula; the shared CPU sample (first call, close calls,
a later call); a part that fails is left out alone; the name and the home folder's volume.
