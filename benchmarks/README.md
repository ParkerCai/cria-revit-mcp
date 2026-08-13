# Cross-provider tool-routing benchmark

This folder tests whether a model can select the correct Cria Revit MCP tools and produce valid arguments from the same synthetic Revit requests. The benchmark is independent of any model vendor, agent product, or API transport.

The inherited benchmark used Claude Haiku as a weak-model stress test. That was useful for exposing unclear tool descriptions, but the runner was tied to Claude Code and the test requests were not in the language used by this project. Haiku is now an optional legacy comparator, not the benchmark identity.

## Current results status

The benchmark runner itself has been validated: 9 Bun tests pass for catalog boundaries, live schemas and annotations, provenance, safety refusal, and scorer behavior. No provider model has been called yet, so Cria does not currently publish a Terra, Luna, Gemini, or Haiku accuracy score. The first run for each exact model and reasoning setting will establish its baseline.

See [the dated validation report](../docs/testing/validation-results-2026-08-12.md) for the completed test inventory and evidence boundaries.

## Default model matrix

The exact machine-readable registry is in `models.json`.

| Provider | Model ID | Default | Purpose |
|---|---|---:|---|
| OpenAI | `gpt-5.6-terra` | Yes | Balanced quality and cost |
| OpenAI | `gpt-5.6-luna` | Yes | Efficient, high-volume tool routing |
| Google | `gemini-3.6-flash` | Yes | Fast agentic and spatial reasoning |
| Anthropic | `claude-haiku-4-5-20251001` | No | Historical comparison only |

The suite also accepts any custom model ID. Add a registry entry with its provider, exact model ID, and reasoning configuration; no scoring changes should be required.

## Files

- `cases.json` contains the canonical English requests and expected tool-call shapes.
- `models.json` records the default model matrix and reproducibility settings.
- `benchmark.ts` captures catalogs, builds prompts, runs adapters, scores responses, and writes local evidence.
- `adapters.local.json.example` defines the provider-neutral local command boundary.
- `template.md` is the provider-neutral runbook and prompt contract.
- `runs/` stores reviewed result reports. Raw provider responses should remain local unless they contain only synthetic benchmark data and are intentionally selected for publication.

## When to run

Run the benchmark before merging when a change:

- adds five or more handlers;
- changes a tool name, description, schema, or safety annotation; or
- precedes a minor or major release.

It is optional for internal refactors and fixes that do not change the MCP surface.

## Automated runner

The Bun runner freezes the catalog, prompt, and output contract and scores strict JSON responses. The v1 routing suite is defined only for `safe-authoring`. Capture a running local Cria server so the payload contains the exact SDK-generated schemas and MCP safety annotations:

```powershell
cd benchmarks
bun test
bun run benchmark.ts catalog --url http://127.0.0.1:8200/ --out .local\safe-catalog.json
bun run benchmark.ts prompt --model gpt-5.6-terra --catalog .local\safe-catalog.json --out .local\terra-prompt.json
bun run benchmark.ts score --model gpt-5.6-terra --catalog .local\safe-catalog.json --prompt .local\terra-prompt.json --response .local\terra-response.json
```

The captured catalog envelope records its source, profile, protocol version, server identity, tool count, safety annotations, instruction hash, and catalog hash. Loading it verifies the profile, every tool referenced by the scored cases, forbidden safe-profile tools, and SHA-256 before use. A partial catalog is rejected instead of turning a missing server capability into a model failure.

When no `--url` or `--catalog` is supplied, `catalog` and `prompt` can use the reflection-derived snapshot fallback for development. `score` and `run` reject that source and require an explicit catalog captured from live `tools/list`.

For automated provider calls, copy `adapters.local.json.example` to ignored `adapters.local.json` and configure a local command adapter. Each adapter receives one prompt JSON document on stdin and must write only the response-contract JSON to stdout:

```powershell
bun run benchmark.ts run --model gpt-5.6-terra --catalog .local\safe-catalog.json --adapters adapters.local.json
```

This interface is provider-neutral. The adapter receives only minimal process environment variables plus the credential names declared in its local configuration. Credentials are never placed in prompts, evidence, or reports. Response provider, model ID, and reasoning must exactly match `models.json`.

Every successful `score` or `run` writes an ignored evidence bundle under `.local/runs/<run-id>/`:

- `catalog.json`: the validated live catalog envelope;
- `cases.json`: the exact scorer expectations whose hash is recorded;
- `prompt.json` and `response.json`: the exact local evidence used for the score;
- `report.md`: the score and provenance summary; and
- `manifest.json`: full commit SHA, dirty state, version, model settings, scores, and SHA-256 values for cases, catalog, catalog envelope, prompt, response, and report.

Use `--report <path>` only to copy the reviewed report to another location. Raw prompts and responses stay under `.local/`; a reviewed public report may be copied to `runs/`.

The automatic scorer checks ordered tools, required arguments, accepted values, derived placeholders, and declared semantic validators. A reviewer must still inspect conflicting optional arguments and any case whose semantics are not fully machine-encoded.

The benchmark plans tool calls only. It must not connect to a production Revit model or execute any tool.

This routing benchmark is distinct from the live cross-server benchmark described in `competitors.md`. Routing compares model use of one frozen tool surface. Live comparison judges the resulting Revit state and does not expect competitors to use the same tool names.

## Comparison policy

Compare a run only with the most recent run that has the same:

- suite version;
- exact model ID;
- reasoning or thinking level; and
- tool-surface profile.

Cross-model scores are useful for product decisions, but they are not regression deltas. The first run for a model establishes that model's baseline.

| Parameter-accuracy change | Reaction |
|---|---|
| Less than 5 percentage points | Treat as normal run variance. |
| 5 to less than 15 percentage points | Review and record the affected cases. |
| 15 percentage points or more | Block the tool-surface change until investigated. |

These are review rules, not CI gates.

## Language and privacy

The canonical suite is English. Translated suites, if added later, must use a separate suite ID so language effects are measurable.

Use only the synthetic requests in `cases.json`. Do not send Revit project names, element data, drawings, paths, or other content from a live Revit project to a benchmark provider. API credentials must stay in environment variables or the provider's local client configuration and must never be written to a run report.
