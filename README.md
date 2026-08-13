<h1 align="center">cria-revit-mcp</h1>

<p align="center">
  Local-first, stateless MCP gateway for Autodesk Revit
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="license" /></a>
  <a href="#runtime-scope"><img src="https://img.shields.io/badge/Revit-2026-186BFF" alt="Revit 2026" /></a>
  <a href="#protocol"><img src="https://img.shields.io/badge/MCP-2026--07--28-6C47FF" alt="MCP 2026-07-28" /></a>
</p>

---

## Status

Cria is an early independent fork. The v0.1 foundation currently provides:

- MCP C# SDK 2.1 and native MCP `2026-07-28` discovery.
- Stateless localhost Streamable HTTP with no `Mcp-Session-Id`.
- Stateless discovery over the default stdio transport.
- No standalone legacy `/sse` endpoint.
- `read-only`, `safe-authoring`, and `developer` profiles.
- Revit 2026 plugin compilation and the inherited multi-version source layout.

There is no Cria installer or production release yet. Do not use the inherited upstream installer to install Cria; its package names and paths still belong to the upstream project.

See [the dated validation report](docs/testing/validation-results-2026-08-12.md), [the v0.1 architecture](docs/cria-v0.1-architecture.md), [the guarded Revit 2026 live smoke test](docs/testing/revit-2026-live-smoke.md), [the MCP conformance baseline](docs/testing/mcp-2026-07-28-conformance.md), and [upstream attribution](UPSTREAM.md).

### Validation snapshot

| Check | Result |
|---|---:|
| .NET suite | 434 passed, 0 failed |
| Provider-neutral benchmark tests | 9 passed, 0 failed |
| Server and Revit 2026 Release builds | Passed |
| Revit 2026 guarded live E2E | Passed: reads, typed authoring, rollback, single Undo, and exact add-in restore |
| Official MCP suite against production server | Baseline only: 104 passed, 67 failed, 13 not scored |
| Live Terra/Luna/Gemini/Haiku scores | Not run |
| Cross-server Revit comparison | Not run |

The live test used a copied local model. One typed batch created a grid, four walls, a floor, and a floor-plan view; a single Ctrl+Z returned the complete element count from 6,644 to the 6,618 baseline and removed all seven recorded IDs. See the validation report for evidence boundaries, defects found, and remaining coverage.

## Developer quick start

Requires the .NET 8 SDK and Revit 2026 for live Revit testing.

```powershell
dotnet test tests/RvtMcp.Tests/RvtMcp.Tests.csproj
dotnet build src/plugin-r26/RvtMcp.Plugin.R26.csproj -c Release -p:RvtMcpSkipDeploy=true
```

Start the MCP server on stdio:

```powershell
dotnet run --project src/server/RvtMcp.Server.csproj -- --target 2026 --profile safe-authoring
```

Or use stateless Streamable HTTP on loopback only:

```powershell
dotnet run --project src/server/RvtMcp.Server.csproj -- --target 2026 --profile safe-authoring --http 8200
```

## Safety profiles

| Profile | Default behavior |
|---|---|
| `read-only` | Removes every model/file-write-capable toolset, including view authoring and atomic batch execution. |
| `safe-authoring` | Default. Typed create and modify tools; deletion and arbitrary C# are absent. |
| `developer` | Adds ToolBaker and `revit_send_code_to_revit`; deletion remains absent unless explicitly requested. |

Explicit `--toolsets` remains an advanced override. In particular, `--toolsets all` exposes destructive and developer surfaces.

## Protocol

- Modern protocol: MCP `2026-07-28`.
- Local transports: stdio and stateless Streamable HTTP.
- Older clients: SDK 2.1 downgrade support remains enabled during migration.
- Application state: the Revit process, active document, UI thread, and transaction state remain explicit Revit concerns even though MCP itself is stateless.

## Runtime scope

- Revit 2026 is the only initial runtime validation target.
- The inherited Revit 2022–2027 projects remain in the repository when they compile without extra maintenance.
- All model data, discovery files, logs, and Revit IPC stay on the workstation.
- The v0.1 server intentionally retains upstream internal namespaces and discovery-file compatibility while product-facing identity changes to Cria.

---

## What this is

`cria-revit-mcp` is a **local** bridge between an MCP client (Claude, Cursor, Codex, OpenCode, …) and a running Revit session.

Two processes:

| Piece | Role |
|--------|------|
| **RvtMcp.Server** | .NET 8 MCP server on stdio. No Revit reference — builds anywhere. |
| **RvtMcp.Plugin** | One thin add-in per Revit year (2022–2027). Runs inside Revit, executes on the UI thread. |

Agent → MCP → server → localhost TCP (≤2024) or Named Pipe (≥2025) → plugin → Revit API.

Everything stays on the machine. No cloud relay is required for the gateway itself.

There is no Node/TypeScript sidecar. Server, plugins, handlers, and ToolBaker are C# end to end. Shared command code lives in `src/shared/`; each year is a small shell project with `#if` where the API drifted. Details: [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Why it exists

People who live in Revit already know what they want automated. The friction was always shipping that idea as software: learn enough C#/Dynamo, fight the API, package an add-in, survive version upgrades — or pay someone else, or buy a fixed tool that only half-matches the office.

Agents change the first half of that loop (describe the task, try it live). They do not remove transactions, units, selection, worksharing, or “did this just trash the model?” That is what this gateway is for: a **typed tool surface** for common work, plus an optional developer profile for ad-hoc C# and personal ToolBaker workflows.

It is not a universal add-in for every firm. Offices differ. The bet is: start from a shared runtime, grow *your* tools on top.

**Scope posture (honest):** we do not mint a new MCP tool for every edge case. Prefer typed tools. The `developer` profile exposes `revit_send_code_to_revit` (C# only) when an experienced user explicitly accepts that risk. Family *project* management is covered; full Family Editor authoring suites and Revit Viewer hosts are out of scope for now — see [docs/roadmap.md](docs/roadmap.md).

---

## How a normal session looks

1. Revit open with a model; plugin connected (ribbon).
2. MCP client starts `cria-revit-mcp` or the locally built server.
3. Agent uses tools: query view/selection, create grids/rooms, sheets, MEP, export, … Lengths in **mm** at the tool boundary.
4. Several audited transaction-only writes in one undo step: `revit_batch_execute`. Its positive allowlist covers core modeling, parameter/type edits, and basic view/sheet/schedule authoring. File, database, UI-selection, deletion, arbitrary C#, baked-tool, and profile-hidden commands are rejected.
5. Multiple Revits running: `revit_list_available_targets` then `revit_switch_target` with a four-digit year (`2024`, not `R24`).

In the opt-in `developer` profile, when no typed tool fits:

```text
revit_send_code_to_revit   # C# body, compiled and run inside the plugin
```

That tool is absent from the default `safe-authoring` profile. Enable it with `--profile developer` or an explicit ToolBaker configuration only when arbitrary C# execution is acceptable.

### ToolBaker (optional)

The `developer` profile exposes:

- `revit_send_code_to_revit`
- `revit_list_baked_tools` / `revit_run_baked_tool` for tools you previously accepted

**Adaptive bake** (suggest new tools from usage) is **off** unless you enable it. When on, repeated patterns can show up under `revit_list_bake_suggestions`; you accept or dismiss explicitly. Nothing ships itself into your ribbon without that step.

Useful flags (also JSON / env — see [Configuration](#configuration)):

| Goal | What to turn on |
|------|------------------|
| Learn tools from repeated **typed** calls | `--enable-adaptive-bake` |
| Also cluster **`send_code`** bodies for suggestions | plus `--cache-send-code-bodies` (redacted; still local) |
| Short-lived disk journal of send_code bodies | `persistSendCodeBodies` + TTL (default privacy keeps this off) |

Bake compile runs **inside Revit** via Roslyn — end users do not need Visual Studio. Details and privacy notes: [docs/bake.md](docs/bake.md).

### Toast (optional)

Completion toast in Revit is **off** by default. Turn on with the ribbon **Toast** button, `enableToast` in config, or `BIMWRIGHT_ENABLE_TOAST=1`. Only finished calls are shown (no “in progress” toast). Capture success can show a thumbnail when the file sits under the path allowlist. Ribbon **Status** also prints toast + bake/privacy flags so you can see what is enabled without guessing.

---

## Architecture (short)

```text
MCP client (stdio)
    → RvtMcp.Server (.NET 8)
        → TCP (Revit 2022–2024) or Named Pipe (2025–2027)
            → Plugin shell (per year)
                → ExternalEvent → Revit API / transactions / undo
```

Handlers return plain DTOs — never live Revit objects on the wire.

---

## Tools

Counts (without counting personal baked tools):

| Mode | Tools | Notes |
|------|------:|-------|
| Default | **214** | Safe authoring; typed create/modify and batch on, destructive operations and ToolBaker off |
| `--toolsets all` | **227** | Adds the destructive tool surface and ToolBaker |
| `all` + adaptive bake | **230** | Adds 3 suggestion-lifecycle tools |

Tool names are MCP-facing as `revit_*`. Wire names between server and plugin stay unprefixed snake_case.

**Default-on toolsets:**  
`query`, `create`, `modify`, `view`, `schedule`, `families`, `mep`, `graphics`, `export`, `meta`, `batch`, `lint`, `sheets`, `materials`, `geometry`, `annotation`, `rooms`, `links`, `parameters`, `organization`, `workflows`, `structural`, `kei`

**Off unless you ask:** `delete`, `toolbaker`
Example: `--toolsets query,view,meta` or `--toolsets all`.  
`--read-only` drops every write-capable toolset.

| Toolset | What it covers | Default |
|---------|----------------|---------|
| `query` | View, selection, filters, stats, parameters, relationships, worksets, groups/assemblies | on |
| `create` | Grids, levels, rooms, line/point/surface-based elements, groups | on |
| `view` | Create views, sheets layout helpers, capture image, crop/scale | on |
| `meta` | Multi-Revit targets, project info queries, message | on |
| `batch` | Positive-allowlist atomic command batches; removed entirely by `read-only` | on |
| `lint` | View naming patterns, firm-profile detect, warnings summary | on |
| `schedule` | List/create schedules, fields, formulas, data | on |
| `families` | Load, types, instances, audit, export `.rfa` (project-side) | on |
| `modify` | Operate/color elements, set parameters and project info, change type, workset assign | on |
| `delete` | Delete, purge, unload, destructive cleanup, and definition removal | off |
| `annotation` | Tags, text, dimensions, regions, keynotes, checks | on |
| `export` | PDF/DWG/IFC/NWC helpers, room data, and related export tools | on |
| `mep` | Systems, connectors, networks, place terminals/fixtures, etc. | on |
| `graphics` | View filters, overrides, visibility/phase | on |
| `toolbaker` | send_code, list/run baked tools; suggestion tools only if adaptive on | off |
| `sheets` | Sheets, titleblocks, revisions, renumber | on |
| `materials` | Materials, appearance, assignment, takeoff | on |
| `geometry` | BBox, measure, clash, volume/area, … | on |
| `rooms` | Rooms/areas/spaces, finishes, separators | on |
| `links` | Revit/CAD links, coordinates | on |
| `parameters` | Project/shared parameters | on |
| `organization` | Saved selections, view templates | on |
| `workflows` | Composite clash/audit/sheet/takeoff-style flows | on |
| `structural` | Columns, beams, foundations, rebar, loads, … | on |
| `kei` | Active KEI project DB path, query/write SQLite (WAL-safe), equipment import | on |

### Representative tools

Not a full dump of 200+ schemas — just anchors agents and humans use often:

| Toolset | Tool | Role |
|---------|------|------|
| `query` | `revit_get_current_view_info` | Active view type, level, scale |
| `query` | `revit_get_selected_elements` | Current selection |
| `query` | `revit_ai_element_filter` | Category + parameter filter (mm) |
| `query` | `revit_get_element_details` | Location, bbox, workset, phase, … |
| `create` | `revit_create_grid` / `revit_create_level` / `revit_create_room` | Core layout |
| `create` | `revit_create_point_based_element` | Doors, furniture, … from type id |
| `view` | `revit_capture_view_image` | Raster capture (path allowlist) |
| `batch` | `revit_batch_execute` | One `TransactionGroup` for exposed typed commands |
| `meta` | `revit_list_available_targets` / `revit_switch_target` | Multi-Revit |
| `families` | `revit_load_family_from_path` | Load `.rfa` into the project |
| `toolbaker` | `revit_send_code_to_revit` | Escape hatch (C#) |
| `toolbaker` | `revit_list_baked_tools` / `revit_run_baked_tool` | Personal accepted tools |
| `toolbaker` | `revit_list_bake_suggestions` | Adaptive only |
| `lint` | `revit_analyze_view_naming_patterns` | Naming outliers |

Golden snapshots in tests pin the exact surface; if counts and code disagree, trust tests/code.

---

## Supported Revit versions

| Revit | Plugin TFM | Transport |
|-------|------------|-----------|
| 2022–2024 | .NET Framework 4.8 | TCP |
| 2025–2026 | .NET 8 (`net8.0-windows7.0`) | Named Pipe |
| 2027 | .NET 10 (`net10.0-windows7.0`) | Named Pipe |

Compile matrix covers all six shells. Runtime depth still varies by year — bake and custom C# should be rechecked on the years you care about.

**Host:** full Revit desktop only. Revit Viewer is not a supported target.

---

## Security and privacy

- Transport is local by default (loopback TCP / local named pipe).
- Discovery files under `%LOCALAPPDATA%\RvtMcp\` include a per-session auth token.
- Tool arguments are schema-checked before handlers run.
- Errors returned to the model are sanitized (path leakage reduced).
- `send_code` can run arbitrary C# in the Revit process — powerful and risky; disable toolbaker if that is unacceptable.
- Adaptive bake, body cache, and TTL journals are **opt-in** and stay under the user profile. Defaults do not write raw send_code bodies to long-lived logs.

More: [SECURITY.md](SECURITY.md), [docs/bake.md](docs/bake.md).

---

## Configuration

Precedence, high wins: **CLI → env (`BIMWRIGHT_*`) →** `%LOCALAPPDATA%\RvtMcp\rvtmcp.config.json`.

| Setting | CLI | Env | JSON |
|---------|-----|-----|------|
| Target year | `--target 2024` | `BIMWRIGHT_TARGET` | `target` |
| Toolsets | `--toolsets query,create` | `BIMWRIGHT_TOOLSETS` | `toolsets` |
| Read-only | `--read-only` | `BIMWRIGHT_READ_ONLY=1` | `readOnly` |
| LAN bind (plugin) | — | `BIMWRIGHT_ALLOW_LAN_BIND=1` | `allowLanBind` |
| ToolBaker surface | `--enable-toolbaker` / `--disable-toolbaker` | `BIMWRIGHT_ENABLE_TOOLBAKER` | `enableToolbaker` |
| Adaptive bake | `--enable-adaptive-bake` / `--disable-adaptive-bake` | `BIMWRIGHT_ENABLE_ADAPTIVE_BAKE=1` | `enableAdaptiveBake` |
| Cache send_code bodies (bake clusters) | `--cache-send-code-bodies` / `--no-…` | `BIMWRIGHT_CACHE_SEND_CODE_BODIES=1` | `cacheSendCodeBodies` |
| Persist send_code journal | `--persist-send-code-bodies` / `--no-…` | `BIMWRIGHT_PERSIST_SEND_CODE_BODIES=1` | `persistSendCodeBodies` |
| Journal TTL | `--persist-send-code-bodies-for 4h` | `BIMWRIGHT_PERSIST_SEND_CODE_BODIES_TTL` | `persistSendCodeBodiesUntil` |
| Completion toast | ribbon **Toast** | `BIMWRIGHT_ENABLE_TOAST=1` | `enableToast` |

After changing server flags, restart the MCP connection so the client picks up the new tool list.

---

## MCP clients

| Client | Wiring |
|--------|--------|
| Claude Code | project `.mcp.json` or `~/.claude.json` |
| Claude Desktop | `%APPDATA%\Claude\claude_desktop_config.json` |
| OpenCode / Codex / Kilo | client-specific local MCP configuration |
| Cursor / Cline / VS Code Copilot | documented JSON layouts |
| Gemini CLI / Antigravity | `gemini mcp add` or settings JSON |

There is no audited Cria installer yet. Start with [.mcp.json.example](.mcp.json.example) or the client-specific references under `docs/`.

---

## Repo layout

```text
cria-revit-mcp/
├── src/
│   ├── RvtMcp.sln
│   ├── server/            # MCP server
│   ├── shared/            # Handlers, transport, ToolBaker, toast, …
│   ├── plugin-r22/ … r27/ # One shell per Revit year
├── tests/                 # xUnit + golden tool lists
├── scripts/               # smoke/development helpers; inherited release workflows are unaudited
├── docs/                  # roadmap, bake, testing
├── AGENTS.md
└── ARCHITECTURE.md
```

---

## Development

```bash
dotnet test tests/RvtMcp.Tests/RvtMcp.Tests.csproj
dotnet build src/server/RvtMcp.Server.csproj -c Release
dotnet build src/plugin-r26/RvtMcp.Plugin.R26.csproj -c Release -p:RvtMcpSkipDeploy=true
```

Close Revit before building plugins if a loaded DLL may be locked. Keep `RvtMcpSkipDeploy=true` during ordinary development so validation does not modify the Revit add-ins folder.

Contribution norms and snapshot rules: [CONTRIBUTING.md](CONTRIBUTING.md).

### Maturity

Usable, not yet a production release. CI compiles the inherited six-shell matrix and runs server tests. Cria runtime validation is currently limited to Revit 2026; use a disposable model and verify every write before using production projects.

---

## More docs

| Doc | Topic |
|-----|--------|
| [AGENTS.md](AGENTS.md) | Development and validation safeguards |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Processes, transport, DTO rules |
| [docs/bake.md](docs/bake.md) | Adaptive bake and body privacy |
| [docs/roadmap.md](docs/roadmap.md) | Near-term hardening and non-goals |
| [docs/testing/validation-results-2026-08-12.md](docs/testing/validation-results-2026-08-12.md) | Completed tests, live Revit findings, benchmark status, and gaps |
| [docs/testing/mcp-2026-07-28-conformance.md](docs/testing/mcp-2026-07-28-conformance.md) | Official-suite production-server baseline |
| [docs/testing/revit-2026-live-smoke.md](docs/testing/revit-2026-live-smoke.md) | Guarded live Revit 2026 procedure |
| [docs/kei-equipment-import.md](docs/kei-equipment-import.md) | KEI SQLite tools (default-on `kei` toolset) |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |

---

## License

Apache-2.0 — [LICENSE](LICENSE).

Cria Revit MCP is derived from [bimwright/rvt-mcp](https://github.com/bimwright/rvt-mcp); see [UPSTREAM.md](UPSTREAM.md) for attribution and retained compatibility details.

Cria v0.1 retains several upstream internal paths and therefore does not support a side-by-side upstream RvtMcp installation yet. Use the guarded Revit 2026 smoke workflow for development deployment and exact restoration.

Revit and Autodesk are trademarks of Autodesk, Inc. Cria is independent and is not affiliated with or endorsed by Autodesk or BIMwright.
