# Live Revit 2026 cross-server benchmark

This benchmark compares end results in Revit, not tool names. Each server may use a different tool surface and call sequence.

The machine-readable server registry is `competitors.json`. The canonical task and oracle contract is `live-cases.v1.json`.

## Current results status

This is a benchmark plan, not a published comparison result. Cria completed its guarded core Revit 2026 smoke test, but none of the competing servers below has been installed or executed under the frozen comparison fixture. No ranking, win claim, or comparative score is currently supported. See [the dated validation report](../docs/testing/validation-results-2026-08-12.md) for what was actually tested.

## Initial comparison set

Run Cria first, then:

1. `mcp-servers-for-revit` as the closest native typed-tool comparison.
2. `Demolinator/revit-mcp-server` for a broader pyRevit/FastMCP comparison.
3. `Sam-AEC/aec-model-bridge` for the larger native-bridge surface.
4. `oakplank/RevitMCP` after verifying Revit 2026 compatibility.

Use BIMwright upstream as a regression baseline rather than an independent competitor.

Do not copy code from AEC Model Bridge into Cria without a license review. Its current licensing differs from Cria's Apache-2.0 license.

## Fixed environment

- Revit 2026 with the exact build recorded.
- One frozen RVT fixture and one pristine copy per case and repeat.
- A local fixture manifest with SHA-256 hashes, exact test level, test origin, selected type IDs, and numeric tolerances.
- The same template, families, units, linked files, and normalized raster-plan package.
- The same model, provider, reasoning level, prompts, and client policy for every server.
- One server installed at a time, or isolated add-in profiles that cannot conflict.
- All servers bound to localhost. Disable cloud or remote providers.
- Record server repository URL, exact commit SHA, version, tool count, and enabled profile.

Run each supported case at least three times. Randomize server order to reduce warm-cache and operator-order effects.

## Two execution tracks

The primary result is typed tools only. Disable arbitrary C#, Python, IronPython, reflection, and generated code when the server permits it.

Run escape-hatch execution separately on disposable, non-workshared files. Never combine those scores with typed-tool results.

For the atomic-failure case, use an advertised transaction-capable operation with parameters that fail after workflow dispatch. An unknown tool rejected before the first operation runs does not prove rollback and must not receive atomicity credit.

## Independent oracle

Score the final RVT state using an independent Revit API oracle, not the server's own response. The oracle should record:

- element IDs, classes, categories, and type IDs;
- geometry, topology, levels, hosts, and parameters;
- views, sheets, schedules, viewports, and schedule instances;
- warning counts and document-modification state;
- before and after counts; and
- whether a case can be removed with one Revit undo when atomicity is claimed.

Use numeric tolerances declared in each case. Unsupported capability is distinct from execution failure.

## Scores

Report separate scores. Do not collapse everything into one unexplained number.

| Area | Measure |
|---|---|
| Capability | Supported required capabilities divided by requested capabilities |
| Correctness | Passed oracle assertions divided by attempted assertions |
| Safety | Rollback, undo, confirmation, dry-run, idempotency, and partial-failure behavior |
| Efficiency | Latency, tool calls, model tokens, schema size, and cold start |
| Operations | Install steps, Revit restarts, admin rights, and third-party runtimes |
| Protocol | Official MCP conformance for the declared protocol version |

Protocol conformance remains separate from Revit task correctness. An older protocol does not erase a correct Revit result.

## Raster-plan boundary

The primary raster case supplies the same normalized geometry package to every server. This isolates Revit execution quality.

A separate vision track may give every model the same raster image. Score the produced intermediate plan representation before running it in Revit. Do not attribute vision mistakes to the Revit bridge.

## Artifact layout

Store private raw runs under the live harness evidence root, not in the repository. A reviewed summary may be copied to `benchmarks/runs/` when it contains only fixture-derived data.

Each run should include:

- environment and repository manifest;
- prompts and model settings;
- sanitized MCP request and response records;
- oracle JSON before and after each case;
- durations and call counts;
- screenshots where useful; and
- cleanup and restoration status.

## Protocol conformance

Use the current source version of the official [Model Context Protocol conformance suite](https://github.com/modelcontextprotocol/conformance) for each server's declared version. Keep the pinned suite commit and raw results with local evidence. Cria's first production-server baseline is documented separately in [the MCP conformance runbook](../docs/testing/mcp-2026-07-28-conformance.md); it is not a conformance pass.
