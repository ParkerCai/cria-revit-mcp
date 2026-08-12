# AGENTS.md — Cria Revit MCP development guide

Cria is a pre-release independent fork. There is no Cria installer or published package yet.

## Rules

1. Preview source and installation changes before writing.
2. Do not run inherited `install.ps1`, packaging, registry, or publishing scripts as Cria workflows until they have been renamed and audited.
3. Do not modify `%APPDATA%\Autodesk\Revit\Addins` unless the user explicitly approves a previewed install.
4. Build Revit projects with `-p:RvtMcpSkipDeploy=true` during ordinary validation.
5. Revit 2026 is the only required runtime target for v0.1. Preserve other project shells when doing so is easy, but do not require other Revit installations.
6. Keep model data, IPC, logs, discovery, and test artifacts on the workstation.
7. Never bypass Revit transactions or the undo stack.
8. Do not commit or push without the user's approval.

## Validate

```powershell
dotnet test tests/RvtMcp.Tests/RvtMcp.Tests.csproj
dotnet build src/server/RvtMcp.Server.csproj -c Release
dotnet build src/plugin-r26/RvtMcp.Plugin.R26.csproj -c Release -p:RvtMcpSkipDeploy=true
```

Modern protocol checks must prove:

- `server/discover` works without `initialize`.
- No `Mcp-Session-Id` is created for modern HTTP requests.
- The standalone legacy `/sse` endpoint is unavailable.
- stdio and localhost Streamable HTTP both identify as `cria-revit-mcp`.

## Compatibility boundary

The v0.1 fork intentionally keeps upstream `RvtMcp.*` namespaces, assembly names, discovery records, named-pipe framing, and `revit_*` tool names. See [UPSTREAM.md](UPSTREAM.md) and [docs/cria-v0.1-architecture.md](docs/cria-v0.1-architecture.md).
