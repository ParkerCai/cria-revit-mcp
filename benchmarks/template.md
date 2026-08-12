# Cross-provider benchmark runbook

Use this runbook for every model. Do not substitute provider-specific tasks, tools, or hidden context.

## 1. Record the repository state

From the repository root, record:

```powershell
git rev-parse --short HEAD
```

Read the version from the `<Version>` element in `src/server/RvtMcp.Server.csproj`. Record the active Cria tool profile and the tool count.

## 2. Load the tool surface

Prefer a current `tools/list` response from a local Cria server. Do not connect the server to a live Revit project for this benchmark.

For an offline run, use:

- schemas from `tests/RvtMcp.Tests/Golden/tools-list.json`; and
- full tool descriptions from the `[McpServerTool]` methods in `src/server/Program.cs`.

Every model in the comparison must receive the same tool names, descriptions, schemas, and safety annotations.

## 3. Select the models

Read `benchmarks/models.json`. Run every entry with `enabledByDefault: true`, or record the exact subset selected by the reviewer. A model not listed there may be used when its provider, exact model ID, and reasoning configuration are recorded in the result.

Do not silently replace a model with a `latest` alias or another tier. If the provider resolves aliases dynamically, record the resolved version when it is available.

## 4. Give each model the same task

Supply the complete tool surface, followed by this prompt and the contents of `benchmarks/cases.json`:

> You are evaluating the Cria Revit MCP tool surface. Plan tool calls for the synthetic requests below. Do not execute any tool and do not connect to Revit. For each case, choose the smallest correct tool or ordered tool chain and provide the arguments you would send. Use only tools from the supplied surface. Preserve numeric units and represent values using the schema's types. When an argument depends on an earlier call result, use a clear placeholder such as `<element IDs returned by call 1>`. Return valid JSON only, using the output shape below. Use English for any notes.

Required output shape:

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
      "id": "Q1",
      "calls": [
        {
          "tool": "revit_tool_name",
          "arguments": {}
        }
      ]
    }
  ]
}
```

Reject and rerun a response that is not valid JSON or omits a case. Record reruns in the report.

## 5. Score the response

Use the expectations in `benchmarks/cases.json`.

For each case:

- **Tool selection:** 1 point when the exact ordered tool chain matches. For a multi-call chain, divide the point equally across call positions.
- **Argument accuracy:** 1 point when every required argument is present and semantically matches an accepted value or rule. Award 0.5 only for one minor representation error that would be trivial to normalize. Otherwise award 0.

Optional arguments do not reduce the score unless they conflict with the request or make the call unsafe. A derived-value placeholder is correct when it clearly refers to the required earlier call.

Report tool-selection and argument-accuracy percentages separately. The overall score is their arithmetic mean.

## 6. Compare like with like

Find the most recent run with the same suite version, exact model ID, reasoning setting, and tool profile. If none exists, label the run as a new baseline. Never calculate a regression delta against a different model.

## 7. Write the run report

Write `benchmarks/runs/<YYYY-MM-DD>-<commit>-<model-id>.md`, replacing characters that are invalid in filenames.

```markdown
# Tool-routing benchmark run — <date>

- Suite: cria-tool-routing-v1
- Commit: <commit>
- Version: <version>
- Provider: <provider>
- Model: <exact model ID>
- Reasoning: <setting>
- Tool profile: <profile>
- Tool count: <count>
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
