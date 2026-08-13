# Revit 2026 live smoke test

The completed 2026-08-12 run and its findings are summarized in [validation-results-2026-08-12.md](validation-results-2026-08-12.md). This file remains the repeatable operator procedure.

This guide exercises Cria against Revit 2026 without using an installer. The harness is local-only, keeps evidence under the ignored `artifacts/live-smoke/` directory, and defaults to a read-only preflight.

Use a non-production, non-workshared seed model. The harness copies any `-ModelPath` before opening it. It never saves, closes, deletes, discards, or replaces either the source model or the copy.

## Prerequisites

- Windows with PowerShell 7.2 or newer, .NET 8, and Revit 2026.
- Revit closed for `Deploy` and `Restore`.
- A local `.rvt` seed file for authoring checks.
- No active Cria harness deployment. `Preflight` reports the current state.

Current development DLLs are unsigned. When Revit shows `Security - Unsigned Add-In`, verify that the location is the exact harness-deployed Cria path recorded for the run and choose `Load Once`. Do not choose `Always Load` for a temporary smoke payload. Signed release binaries are tracked separately on the roadmap.

Run every command from the repository root.

## 1. Preflight and build

Preflight only reads files and process state:

```powershell
pwsh scripts/revit-2026-smoke.ps1
```

Build runs the test project, server build, and Revit 2026 plugin build. The plugin command always sets `RvtMcpSkipDeploy=true`:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase Build
```

## 2. Preview and deploy

First preview the exact source, target, and backup paths:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase Deploy -WhatIf
```

After reviewing that output, deploy the exact hashed payload:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase Deploy -ApproveAddinChange
```

Deploy refuses to run while Revit is open. Existing `RvtMcp.R26.addin` and `RvtMcp` targets are copied to the run evidence directory and moved to inactive sibling paths. Each copy and move is checked with SHA-256 inventories and journaled immediately. Failure rollback archives a target only after the harness has recorded or hash-reconciled that its own staged payload reached that exact target; an early failure cannot remove the pre-existing add-in. If PowerShell stops between moves, rerunning `Restore` previews and reconciles target, staging, inactive-original, and backup hashes before completing rollback.

## 3. Run the live checks

For a read-only session, either open Revit 2026 and a disposable model yourself, or let the harness open a copied seed model:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase Run -LaunchRevit -ModelPath C:\Models\CriaSeed.rvt
```

The read-only run verifies:

- MCP `2026-07-28` discovery, the `cria-revit-mcp` identity, and `Mcp-Name` on tool calls.
- No `Mcp-Session-Id` response header and a `404` response from legacy `/sse`.
- Tool filtering, including absence of all ten delete-boundary tools and arbitrary C# under both supported profiles, plus absence of batch, view writes, and project-info writes under `read-only`.
- A live Revit 2026 named-pipe target, current view, model statistics, and warnings. The full composite model audit also runs when the selected profile exposes the `workflows` toolset; the strict read-only profile strips that entire mixed read/write toolset.

The authoring session is optional; the read-only smoke can be run by itself. If you choose authoring, close all Revit instances first. The harness must launch the copied model itself:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase Run -Profile safe-authoring -LaunchRevit -ModelPath C:\Models\CriaSeed.rvt -RunAuthoring -ApproveModelChanges
```

Choose either read-only or safe-authoring for one deployment. If a read-only server is already running, collect and restore that run, then deploy a fresh run before starting safe-authoring; the harness will not replace a running server with a different profile.

If the `Run` PowerShell process exits while the active state is already `Running`, leave Revit and the harness-owned server open. Rerun `Run` with the same profile and HTTP port. The resume path does not start, stop, or replace either process. It first matches the server PID, executable, start time, profile, port, hash inventory, Revit PID/start time/discovery, and the run-owned copied-model path. For example:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase Run -Profile safe-authoring -HttpPort 8200 -RunAuthoring -ApproveModelChanges
```

Each invocation writes to a new `http-attempt-*` directory and records `attempt.json`; a caught failure also writes `failure.json` with its phase and PowerShell error details. Earlier partial evidence is never overwritten. Resume refuses to run if steps `10` through `15` left any authoring evidence without a matching recorded authoring result, because repeating an uncertain model mutation is unsafe. In that case, inspect and collect evidence, then restore rather than retrying authoring.

Before any model write, the authoring run probes deterministic candidate volumes with the read-only `revit_find_elements_in_volume` tool. It selects only a complete, non-truncated volume with no intersecting walls, floors, or structural foundations, records the selected offset, and applies that same translation to the grid, walls, and floor. Grid datum extents are deliberately excluded from the occupancy test because they can cross otherwise empty model regions and do not predict wall or floor overlap.

The authoring run then proves a failed batch rolls back. Its second command is an allowlisted zero-length grid that reaches Revit and fails there, after the temporary level command has run. The harness requires that temporary level ID to stop resolving and rejects capped or truncated model statistics before using count equality as supporting evidence. It then creates one grid, four walls, one floor, and one floor-plan view in one Revit undo item. The harness records every returned element ID, checks that the wall and floor bounding boxes remain inside the selected empty volume, and requires the surface element to resolve as `Floors`, never `Structural Foundations`.

In Revit, press Ctrl+Z exactly once and confirm the undo item is `MCP: batch_execute`. Do not close Revit yet. Verify that undo through MCP:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase VerifyUndo
```

Once authoring has run, the single-Undo check is required to call that authoring smoke complete. Verification first rechecks the recorded Revit PID, executable, start time, discovery PID, and active project title. It also compares Revit's canonical active-document path exactly with the recorded copied-model path. It rejects capped or truncated statistics, then requires all recorded IDs to be gone and the counted element total to match its baseline. On success it records `undoRequired=false` and archives `UNDO_REQUIRED.txt` as `UNDO_INSTRUCTIONS.archived.txt`, so the run cannot be mistaken as still awaiting Undo. Repeating `VerifyUndo` exits without further MCP calls. If verification cannot be completed, `Collect` and `Restore` remain available for evidence capture and safe add-in recovery, but the run retains `undoRequired=true` and must be reported as an incomplete Undo check. If verification fails, inspect Revit's undo history; do not press Undo repeatedly.

## 4. Collect evidence

While the session is still available, collect local evidence:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase Collect
```

Evidence includes request and response bodies, server stdout and stderr, full server-runtime and add-in hash inventories, sanitized Revit discovery, and only the log bytes appended after the run started. The required server inventory includes the executable, managed DLL, dependency manifest, and runtime configuration. The discovery authentication token is omitted.

An HTTP timeout during an authoring call is an indeterminate result, not proof of failure. Do not repeat the call. Wait for the plugin call journal to finish or become quiescent, inspect its transaction result, and use read-only ID and complete-statistics checks to prove the final model state before collecting and restoring the run.

## 5. Restore

You decide whether to save or discard the copied model, then close Revit yourself. The harness never makes that decision.

Preview restoration:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase Restore -StopOwnedServer -WhatIf
```

Restore the exact pre-smoke add-in state and stop only the server process recorded by this harness:

```powershell
pwsh scripts/revit-2026-smoke.ps1 -Phase Restore -StopOwnedServer -ApproveAddinChange
```

Before stopping a process, the harness matches its PID, executable path, start time, SHA-256 hash, and full server-runtime inventory. Server startup identity is journaled immediately after process creation, before startup delay and readiness checks. It does not search for or stop other MCP servers. Restore refuses to overwrite an add-in payload whose hashes changed after deployment, journals each archive/restore move, and completes an interrupted restore only after recognizing exact pre-deploy or smoke hashes. A partial run-owned restore staging copy is inventoried and archived as unverified recovery evidence; it is never mistaken for the complete original. The smoke payload is moved into the run evidence directory rather than deleted.

## Recovery and limitations

The active pointer is `artifacts/live-smoke/active-deployment.json`; its referenced `state.json` records exact paths and hashes. Keep that run directory until restoration is complete. If a hash check blocks restore, inspect the changed file and state rather than moving add-in files manually.

This harness covers protocol behavior, live reads, model audit, a small typed modeling batch, transaction rollback, and one-step undo. It does not yet automate raster-plan ingestion, title-block selection, sheet layout, schedule authoring, exports, screenshots, worksharing, or model-save behavior. Those need separate fixture-specific scenarios after this core smoke test is stable.
