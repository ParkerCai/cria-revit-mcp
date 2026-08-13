# MCP 2026-07-28 conformance

Cria declares MCP `2026-07-28`. Protocol conformance is measured separately from Revit task correctness and from the model tool-routing benchmark.

Use the current source version of the official [Model Context Protocol conformance suite](https://github.com/modelcontextprotocol/conformance). The published package may lag the repository and may not recognize `--requirements 2026-07-28`.

## Production-server baseline

On 2026-08-12, the official suite at commit `c321dd32035556e6769d3724a8ee97d87c3faaac` was run against a local Cria safe-authoring server. It reported:

- 104 checks passed;
- 67 checks failed; and
- 13 scenarios were not scored by the suite.

This is a baseline, not a conformance pass. Most failures require diagnostic fixtures that a production Revit server should not expose, including synthetic tools, resources, prompts, completion handlers, and intentional error cases. The production server did pass useful checks for tool and resource listing, multiple SSE streams, resource-not-found handling, DNS rebinding protection, and parts of stateless behavior.

Raw results stay outside the repository under the workstation-local test evidence directory. Do not publish them without reviewing paths and payloads.

## Required next step

Build a separate test-only conformance host that uses Cria's real transport and middleware but registers the diagnostic fixtures expected by the suite. Do not add those fixtures to the production Revit tool surface.

The test host must:

- bind only to loopback;
- contain no Revit document data;
- be impossible to enable through normal production arguments;
- use the same MCP SDK and `2026-07-28` stateless transport configuration as the server;
- run the full official suite from a pinned source commit; and
- save the suite version, Cria commit, dirty-worktree state, command, and raw results in local evidence.

Only call Cria conformant after every applicable mandatory scenario passes or an official suite rule marks it not applicable. Missing diagnostic fixtures are not evidence of a production protocol defect, but they also cannot be counted as a pass.

## Local command shape

Start a safe-authoring server on an unused loopback port:

```powershell
src/server/bin/Release/net8.0/RvtMcp.Server.exe --target 2026 --profile safe-authoring --disable-toolbaker --http 8201
```

From a pinned checkout of the official suite:

```powershell
bun install --ignore-scripts
bun run build
bun run dist/index.js server --url http://127.0.0.1:8201/ --requirements 2026-07-28 --output-dir results --verbose
```

Stop only the exact server process started for the test. Keep protocol results separate from live Revit smoke evidence and cross-server benchmark scores.
