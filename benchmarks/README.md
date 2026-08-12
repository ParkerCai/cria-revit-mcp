# Cross-provider tool-routing benchmark

This folder tests whether a model can select the correct Cria Revit MCP tools and produce valid arguments from the same synthetic Revit requests. The benchmark is independent of any model vendor, agent product, or API transport.

The inherited benchmark used Claude Haiku as a weak-model stress test. That was useful for exposing unclear tool descriptions, but the runner was tied to Claude Code and the test requests were not in the language used by this project. Haiku is now an optional legacy comparator, not the benchmark identity.

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
- `template.md` is the provider-neutral runbook and prompt contract.
- `runs/` stores reviewed result reports. Raw provider responses should remain local unless they contain only synthetic benchmark data and are intentionally selected for publication.

## When to run

Run the benchmark before merging when a change:

- adds five or more handlers;
- changes a tool name, description, schema, or safety annotation; or
- precedes a minor or major release.

It is optional for internal refactors and fixes that do not change the MCP surface.

## How to run

1. Start the Cria server or load the current tool surface from `tests/RvtMcp.Tests/Golden/tools-list.json` plus the descriptions in `src/server/Program.cs`.
2. Follow `template.md` once for each enabled model in `models.json`.
3. Give every model the same tool definitions, English cases, output schema, and comparable reasoning setting.
4. Save a reviewed report to `runs/<date>-<commit>-<model-id>.md`.

The benchmark plans tool calls only. It must not connect to a production Revit model or execute any tool.

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

Use only the synthetic requests in `cases.json`. Do not send model names, element data, drawings, paths, or other content from a live Revit project to a benchmark provider. API credentials must stay in environment variables or the provider's local client configuration and must never be written to a run report.
