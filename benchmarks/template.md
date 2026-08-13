# Cross-provider benchmark runbook

Use this runbook for every model. Do not substitute provider-specific tasks, tools, or hidden context.

## 1. Record the repository state

The runner records the full commit SHA, dirty worktree state, and server package version in `manifest.json`. Before a publishable run, inspect the worktree intentionally:

```powershell
git status --short
git rev-parse HEAD
```

The v1 suite uses the `safe-authoring` profile only.

## 2. Load the tool surface

Capture the live tool catalog and generate the frozen provider-neutral payload with:

```powershell
cd benchmarks
bun run benchmark.ts catalog --url http://127.0.0.1:8200/ --out .local\safe-catalog.json
bun run benchmark.ts prompt --model <exact-model-id> --catalog .local\safe-catalog.json --out .local\prompt.json
```

The catalog command calls stateless `server/discover` and `tools/list`, rejects session IDs, verifies the Cria server identity and `2026-07-28`, and records a catalog SHA-256. The prompt embeds that catalog provenance.

If a live server is unavailable, `catalog` and `prompt` can use the offline snapshot for development. `score` and `run` do not accept offline catalogs.

Every model in the comparison must receive the same tool names, descriptions, schemas, and safety annotations.

## 3. Select the models

Read `benchmarks/models.json`. Run every entry with `enabledByDefault: true`, or record the exact subset selected by the reviewer. A model not listed there may be used when its provider, exact model ID, and reasoning configuration are recorded in the result.

Do not silently replace a model with a `latest` alias or another tier. If the provider resolves aliases dynamically, record the resolved version when it is available.

## 4. Give each model the same task

Supply the complete tool surface, followed by this prompt and the contents of `benchmarks/cases.json`:

> You are evaluating the Cria Revit MCP tool surface. Plan tool calls for the synthetic requests below. Do not execute any tool and do not connect to Revit. For each case, choose the smallest correct tool or ordered tool chain and provide the arguments you would send. Use only tools from the supplied surface. Preserve numeric units and represent values using the schema's types. When an argument depends on an earlier call result, use a clear placeholder such as `<element IDs returned by call 1>`. Return valid JSON only, using the output shape below. Use English for any notes.

Required response shape: return exactly one result for every supplied case ID. `calls` is an ordered array with zero or more entries. Use an empty array when no supplied tool should be called.

```json
{
  "suite": "cria-tool-routing-v1",
  "model": {
    "provider": "provider-name",
    "id": "exact-model-id",
    "reasoning": "exact-setting"
  },
  "results": [
    {
      "id": "<one supplied case id>",
      "calls": []
    }
  ]
}
```

When calls are required, each entry has shape `{"tool":"revit_tool_name","arguments":{}}`. Do not return the angle-bracket placeholder literally.

Reject and rerun a response that is not valid JSON or omits a case. Record reruns in the report.

## 5. Score the response

Prefer the repeatable scorer:

```powershell
bun run benchmark.ts score --model <exact-model-id> --catalog .local\safe-catalog.json --prompt .local\prompt.json --response <response-json>
```

The scorer verifies that the catalog is a live capture, its hashes and safe profile are intact, the prompt matches the catalog/cases/registry contract, and response provider/model/reasoning match `models.json`.

Use the expectations in `benchmarks/cases.json`.

For each case:

- **Tool selection:** 1 point when the exact ordered tool chain matches. For a multi-call chain, divide the point equally across call positions.
- **Argument accuracy:** 1 point when every required argument is present and semantically matches an accepted value or rule. Award 0.5 only for one minor representation error that would be trivial to normalize. Otherwise award 0.

Optional arguments do not reduce the score unless they conflict with the request or make the call unsafe. A derived-value placeholder is correct when it clearly refers to the required earlier call.

Report tool-selection and argument-accuracy percentages separately. The overall score is their arithmetic mean.

## 6. Compare like with like

Find the most recent run with the same suite version, exact model ID, reasoning setting, and tool profile. If none exists, label the run as a new baseline. Never calculate a regression delta against a different model.

## 7. Review the evidence bundle

Each successful score writes `.local/runs/<run-id>/catalog.json`, `cases.json`, `prompt.json`, `response.json`, `report.md`, and `manifest.json`. The manifest contains the full commit, dirty state, version, exact model tuple, scores, and hashes for every scored input and output.

Review `.local/runs/<run-id>/report.md`. Copy only that reviewed report to `benchmarks/runs/<YYYY-MM-DD>-<commit>-<model-id>.md` when publication is intended.

```markdown
# Tool-routing benchmark run — <date>

- Suite: cria-tool-routing-v1
- Commit: <commit>
- Dirty worktree: Yes or No
- Version: <version>
- Provider: <provider>
- Model: <exact model ID>
- Reasoning: <setting>
- Tool profile: <profile>
- Tool count: <count>
- Catalog source: live-tools-list
- Catalog SHA-256: <hash>
- Cases SHA-256: <hash>
- Prompt SHA-256: <hash>
- Response SHA-256: <hash>
- Baseline: <path or New baseline>
- Reruns: <count and reason>

## Score

| Tool selection | Argument accuracy | Overall | Delta vs matching baseline |
|---:|---:|---:|---:|
| X% | Y% | Z% | N/A or +/- N points |

## Regressions

List each changed case, the current output, the matching baseline output, and the likely tool-description or schema cause. Write `None` when there are no regressions.

## Case results

| Case | Expected tools | Model tools | Tool score | Argument score | Notes |
|---|---|---|---:|---:|---|
| Q1 | ... | ... | 1.0 | 1.0 | ... |
```

Do not commit or publish raw provider reasoning. Do not include credentials, live Revit data, or local machine paths.

## 8. Summarize

Report:

- exact provider, model ID, and reasoning setting;
- tool-selection, argument-accuracy, and overall scores;
- delta against the matching baseline, if one exists;
- cases that regressed; and
- recommendation: `Pass`, `Review`, or `Block`.
