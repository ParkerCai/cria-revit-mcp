# Contributing to Cria Revit MCP

Cria is an early independent fork focused on local-only, stateless MCP access to Revit. Open an issue before a large change so scope and compatibility expectations are clear.

## Development setup

Required:

- Windows 10 or 11;
- .NET 8 SDK;
- Revit 2026 for live runtime tests.

The inherited Revit 2022-2027 project shells use NuGet Revit API references and remain in CI. Other local Revit installations are not required for ordinary work on Cria v0.1.

```powershell
git clone https://github.com/ParkerCai/cria-revit-mcp.git
cd cria-revit-mcp
dotnet test tests/RvtMcp.Tests/RvtMcp.Tests.csproj
dotnet build src/server/RvtMcp.Server.csproj -c Release
dotnet build src/plugin-r26/RvtMcp.Plugin.R26.csproj -c Release -p:RvtMcpSkipDeploy=true
```

Do not run the inherited installation, packaging, registry, or publishing scripts as Cria workflows until they have been renamed and audited. Keep `RvtMcpSkipDeploy=true` during ordinary validation so a build does not modify the Revit add-ins folder.

## Project structure

| Path | Purpose |
|---|---|
| `src/server/` | MCP server, stateless HTTP/stdio transports, and tool registration |
| `src/shared/Handlers/` | Revit command handlers |
| `src/shared/Infrastructure/` | Dispatch, validation, transaction, and response infrastructure |
| `src/shared/Transport/` | Local Revit IPC |
| `src/plugin-r26/` | Initial Revit 2026 runtime target |
| `src/plugin-r22/` through `plugin-r27/` | Preserved compatibility shells |
| `tests/RvtMcp.Tests/` | .NET tests and golden tool snapshots |
| `benchmarks/` | Provider-neutral model tool-routing benchmark |

## Changes to MCP tools

When adding or changing a tool:

1. Keep Revit objects inside the plugin process and return plain DTOs.
2. Preserve Revit transactions and undo behavior for writes.
3. Put destructive or arbitrary-code capabilities behind the correct safety profile.
4. Add focused tests for non-trivial behavior.
5. Update the golden tool snapshot intentionally and review its diff.
6. Run the cross-provider benchmark when names, descriptions, or schemas change materially.

The benchmark procedure is in [benchmarks/README.md](benchmarks/README.md). It is model-agnostic; regression comparisons must use the same exact model and reasoning configuration.

## Pull requests

- Keep changes focused and explain user-visible behavior.
- State which Revit year was runtime-tested. Revit 2026 is sufficient for v0.1 unless the change is version-specific.
- Include the validation commands and results.
- Do not include live model data, local paths, credentials, or raw provider reasoning.
- Do not add AI attribution to commits or pull requests.

Security-sensitive reports should follow [SECURITY.md](SECURITY.md), not a public issue.
