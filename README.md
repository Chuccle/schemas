# schemas: the server-rs ↔ BlorgFS contract

[server-rs](https://github.com/Chuccle/server-rs) and the [BlorgFS](https://github.com/Chuccle/BlorgFS) driver are built separately and talk over HTTP. Both repositories pin this one as a submodule (`schemas/` and `third_party/schemas/`). Everything they have to agree on is defined here once.

| File | What it is |
|---|---|
| `metadata_flatbuffer.fbs` | The FlatBuffers schema for directory listings and entry metadata. |
| `contract.json` | **The source of truth.** Contract version, routes, query key, status codes, the exact request bytes the driver sends, golden metadata fixtures, and the behaviours each side relies on. |
| `tools/generate.py` | Builds everything below from `contract.json`. |
| `fixtures/*.bin` | Golden FlatBuffer bodies encoded by `flatc` (generated). |
| `generated/blorg_contract.h` | Kernel-safe C macros for routes, statuses and the version. The driver builds its request lines from these (generated). |
| `generated/blorg_contract_fixtures.h` | Request and fixture tables for the driver's sandbox tests (generated). |
| `generated/blorg_contract.rs` | The same data for server-rs, which takes its routes from here (generated). |
| `tools/check_traceability.py` | Fails when a behaviour has no test claiming to check it. |
| `conformance/Test-BlorgContract.ps1` | Live probe: checks a running server against the behaviours over raw HTTP, the way the driver talks to it. |

## What "the contract" covers

A change can break the pair without breaking anything you'd call an API, so the contract has two layers.

**Structural.** This layer covers routes, the `path` query key, status codes, and the FlatBuffer layout. Both sides compile against the generated files. Renaming a route on one side without the contract doesn't compile. Both decoders read the golden fixtures in `fixtures/`: flatbuffers-rs in server-rs and flatcc in the driver. server-rs also checks that its own encoder writes the same values.

**Behavioural.** These are the things each side assumes about how the other one behaves. They're listed in `contract.json` → `behaviours`, each with an ID:

| ID | Behaviour |
|---|---|
| B01 | Ranged reads get a 206 with exactly the requested length, whether the file is resident or streamed. |
| B02 | Every response has a Content-Length and is never chunked. |
| B03 | Keep-alive connections stay open, so the driver can reuse its connection pool. |
| B04 | Errors are status codes only. Each code maps to a specific NTSTATUS in the driver. |
| B05 | Windows paths are accepted as the driver sends them: backslashes, the root as `\`, and `..` handled. |
| B06 | Listings are well formed: both vectors present, unique names that fit the driver's limit, byte-wise sorted. |
| B07 | Metadata decodes to the same values on both sides. |
| B08 | Metadata and content agree, including after a file changes on the host. |
| B09 | *Gap:* the driver matches names without regard to case, but a Linux host doesn't. |
| B10 | Timestamps are FILETIME and never 0. |
| B11 | *Gap:* a read that crosses the end of a file that has since shrunk fails instead of returning short. |

Each behaviour lists who checks it in `checked_by`: `server-rs`, `BlorgFS`, or `guest`. That means the live probe running against a deployed server, for example inside the Windows test guest. A check claims a behaviour with a `contract: B04` comment next to it. Each repo's CI runs `check_traceability.py` against the contract it pins and fails if a behaviour it's responsible for has no tagged check. Adding a behaviour therefore forces both sides to write the test.

A `gap` behaviour describes something known to be broken. It's written down so it can't be forgotten. Nothing requires a test for it, and the probe reports it as INFO without failing.

## Changing the contract

1. Edit `contract.json`. Bump `version.minor` for an additive change both sides tolerate, or `version.major` for anything an already-built peer would misread.
2. Run `python3 tools/generate.py` (it needs `flatc` 25.12.19 on PATH or in `$FLATC`) and commit the generated files. CI runs `--check` and fails on anything stale.
3. Land it here first, then server-rs adopting it, then one BlorgFS PR that moves both pins (BlorgFS's package-pins check fails if the driver and the pinned server compile different commits of this repo).

## Running the probe

```powershell
# Against a local server whose served directory you can write to (enables the change tests)
./conformance/Test-BlorgContract.ps1 -Server 127.0.0.1:8080 -SeedRoot /srv/blorg

# Inside the Windows test guest, against a deployed server (seed first, wherever the served directory lives)
.\conformance\Test-BlorgContract.ps1 -Server 10.0.50.17:8080 -ResultPath C:\results\contract.json
```

`-ProbeDir` names the probe tree's directory under the served root (default `contract-probe`). Where the probe can't write to the served directory, serve a committed copy of what `-SeedOnly` writes; the change tests (B08, B11) then report as skipped. BlorgFS commits that copy as `tests/guest-suites/Contract.corpus/`.

It needs only PowerShell (Windows PowerShell 5.1 or pwsh 7). The exit code is the number of failed checks.
