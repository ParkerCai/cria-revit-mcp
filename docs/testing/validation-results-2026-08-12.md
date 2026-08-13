# Validation results - 2026-08-12

This report separates completed validation from planned benchmark work. It is the release-evidence summary for the current Cria v0.1 candidate; raw live-model evidence remains workstation-local and ignored by Git.

## Summary

| Area | Result | What it establishes |
|---|---:|---|
| .NET tests | 434 passed, 0 failed | Server metadata, safety profiles, stateless transports, tool snapshots, batch policy, category and floor guards, manifest identity, and harness contracts |
| Benchmark runner tests | 9 passed, 0 failed | Provider-neutral catalog, provenance, prompt, and scoring behavior |
| Server Release build | Passed | .NET 8 MCP server compiles |
| Revit 2026 Release build | Passed, 0 errors | R26 plugin compiles with deployment disabled; a clean audit build reported 79 existing Revit-obsolescence and Windows-platform warnings |
| PowerShell validation | Passed | Smoke harness SelfTest and parser checks for guarded development/release scripts |
| Revit 2026 live E2E | Passed | Local stateless MCP, safe tool filtering, live reads, typed authoring, rollback, one-step Undo, and exact add-in restoration |
| MCP official-suite baseline | 104 passed, 67 failed, 13 not scored | Useful production-server baseline, not a conformance pass |
| Terra/Luna/Gemini/Haiku model scores | Not run | Runner and model registry exist, but no provider responses have been scored |
| Competing Revit MCP execution | Not run | Fair comparison protocol and server registry exist, but competitors have not been installed or executed |

## Commands validated

```powershell
dotnet test tests/RvtMcp.Tests/RvtMcp.Tests.csproj -c Release --no-restore
dotnet build src/server/RvtMcp.Server.csproj -c Release --no-restore
dotnet build src/plugin-r26/RvtMcp.Plugin.R26.csproj -c Release --no-restore -p:RvtMcpSkipDeploy=true
pwsh scripts/revit-2026-smoke.ps1 -Phase SelfTest
cd benchmarks
bun test
```

CI now runs the .NET suite, the provider-neutral Bun tests, and the inherited R22-R27 compilation matrix with deployment disabled.

## .NET coverage and findings

The 434-test suite includes:

- MCP `2026-07-28` stateless discovery over HTTP and stdio;
- safe-authoring discovery that omits deletion, destructive cleanup, ToolBaker, and arbitrary C#;
- strict read-only removal of batch execution, view authoring, project-info writes, and all other write-capable toolsets;
- bounded server instructions and server/profile metadata;
- golden snapshots for the default, all-toolsets, and adaptive-bake surfaces;
- a positive atomic-batch allowlist enforced by both server and plugin boundaries;
- rollback propagation for handlers that previously returned error-shaped successful DTOs;
- non-foundation floor-type selection and rejection of invalid explicit floor types;
- nested MCP `JsonElement` to `JObject` normalization for volume queries;
- fail-closed category parsing and resolution for volume queries;
- independent Revit add-in name, vendor, and GUID across R22-R27;
- fail-fast guards on inherited installer, uninstaller, migration, staging, and packaging scripts; and
- smoke-harness deployment, recovery, server identity, copied-model provenance, rollback, and Undo contracts.

The exact MCP-facing default surface is 214 tools. `--toolsets all` exposes 227, and enabling adaptive bake on that surface exposes 230. The routing benchmark rejects a live catalog that omits any tool used by its scored cases.

## Revit 2026 live E2E

The successful guarded run used `safe-authoring`, stateless HTTP on loopback, a harness-owned server, and a copied local RVT. Run evidence is stored locally under:

```text
artifacts/live-smoke/20260812-183035-ef6617c0/
```

The directory is ignored by Git and was not included in the public repository.

### Protocol and safety checks

- MCP discovery declared `2026-07-28` and did not require `Mcp-Session-Id` state.
- The server found the exact live Revit 2026 named-pipe target.
- Discovery and the live tool list omitted raw deletion, destructive cleanup, ToolBaker, and `revit_send_code_to_revit` under `safe-authoring`.
- Read calls returned the current target, current view, complete model statistics, warning summary, and model audit data.
- The active document path matched the harness-owned copied model exactly before authoring and during Undo verification.

### Placement and authoring

The model already contained geometry near its origin, so the harness probed deterministic candidate volumes before writing. It selected candidate 1 at an offset of `50,000 mm, 50,000 mm` after confirming no intersecting walls, floors, or structural foundations.

One atomic typed batch created:

- one grid;
- four walls;
- one floor; and
- one floor-plan view.

All seven returned IDs resolved after creation. Wall and floor bounding boxes stayed inside the selected probe region. The surface element resolved as category `Floors`, not `Structural Foundations`.

### Rollback and Undo proof

The rollback scenario created a temporary level, then deliberately issued an allowlisted zero-length grid that failed inside Revit. With `continueOnError=false`, the plugin reported `rolledBack=true`. The temporary level ID no longer resolved, and complete before/after model statistics matched.

For the successful authoring batch:

- baseline counted elements: `6,618`;
- after authoring: `6,644`;
- one Revit Undo item: `MCP: batch_execute`;
- after one Ctrl+Z: `6,618`; and
- all seven recorded authoring IDs no longer resolved.

This proves the tested batch was a single Revit Undo item. It does not prove that every possible command can be batched; Cria intentionally permits only commands in its audited transaction-only allowlist.

### Cleanup and workstation state

- Revit and the harness-owned MCP server were stopped.
- The exact pre-test add-in manifest and plugin payload were restored by recorded SHA-256 inventories.
- The source RVT was not used for writes; authoring occurred only in the run-owned copy.
- No model was automatically saved, closed, deleted, or discarded by the harness.

## Defects found during E2E and fixed

The live work exposed issues that server-only tests did not reveal:

1. Successful JSON-RPC objects omit `error`; PowerShell StrictMode previously dereferenced the missing property and aborted a valid run.
2. JSON-deserialized timestamps lost their UTC interpretation during resume checks.
3. Interrupted deployment and restore state needed per-move journaling and safe property insertion on deserialized objects.
4. MCP SDK nested `object` input arrived as `System.Text.Json.JsonElement`, requiring explicit conversion before the Newtonsoft-based plugin gateway.
5. Generic floor selection could choose a structural foundation slab instead of an architectural floor.
6. Fixed-origin authoring could collide with existing model geometry, so placement now probes an empty volume first.
7. `VerifyUndo` needed an idempotent checkpoint, `undoRequired=false`, and archival of the actionable Undo marker.
8. Volume category filtering could silently apply a partial or empty filter; it now fails before querying when any supplied category is malformed or unresolved.
9. Batch execution required a positive allowlist at both the server and plugin boundary because file, database, UI, deletion, and arbitrary-code side effects cannot be rolled back by a Revit `TransactionGroup`.

The successful live run exercised the core protocol, authoring, rollback, floor, geometry-input, and Undo fixes. The later category-resolution hardening, Cria manifest identity, CI, docs, and release-script guards were validated by unit tests and builds. A tagged release should repeat the guarded live smoke from the exact release commit so the evidence SHA and repository state are fully reproducible.

## Protocol conformance baseline

The official Model Context Protocol conformance suite at pinned commit `c321dd32035556e6769d3724a8ee97d87c3faaac` reported 104 passed checks, 67 failed checks, and 13 unscored scenarios against the production Cria server.

This is not a conformance pass. Many failures expect diagnostic tools, resources, prompts, completion handlers, and intentional error fixtures that should not exist on the production Revit surface. The next protocol step is a test-only host that shares Cria's transport and middleware while exposing only the official diagnostic fixtures. Details are in [mcp-2026-07-28-conformance.md](mcp-2026-07-28-conformance.md).

## Benchmark status

### Provider-neutral routing benchmark

The benchmark implementation is complete enough to produce reproducible local scores. Its 9 automated tests cover:

- the exact 214-tool safe-authoring profile boundary;
- live `tools/list` JSON Schemas and MCP safety annotations;
- rejection of partial or tampered catalogs;
- exact provider, model ID, and reasoning metadata;
- self-contained evidence manifests and SHA-256 provenance;
- numeric type-representation scoring;
- rectangle dimensions and non-self-intersection;
- the no-tool deletion case when deletion is unavailable; and
- rejection of argument credit for the wrong tool.

Configured default models are GPT-5.6 Terra, GPT-5.6 Luna, and Gemini 3.6 Flash. Claude Haiku is disabled by default and retained only as a historical weak-model comparator.

No model provider was called during this validation, so there are no routing accuracy scores yet. The first valid run for each exact model and reasoning setting will establish its baseline rather than a regression claim.

### Cross-server Revit benchmark

The comparison design and registry cover:

- `mcp-servers-for-revit`;
- `Demolinator/revit-mcp-server`;
- `Sam-AEC/aec-model-bridge`;
- `oakplank/RevitMCP`; and
- BIMwright upstream as a regression baseline.

No competing server was installed or executed. There is therefore no ranking or comparative performance claim. The planned benchmark uses the same frozen Revit 2026 fixture, a fresh copy for every case, identical model/provider settings, independent Revit API end-state oracles, at least three repetitions, randomized server order, and separate typed-tool and arbitrary-code tracks.

## Remaining coverage

The completed live E2E does not yet cover:

- raw raster-plan ingestion or vision quality;
- fixture-driven sheet, title-block, viewport, or schedule authoring;
- exports and output-file validation;
- workshared model behavior;
- model save behavior;
- Revit runtime execution on 2022-2025 or 2027;
- official full MCP conformance; or
- live model/provider or competing-server benchmark scores.

These are follow-up scenarios, not implied passes.
