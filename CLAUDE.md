# Cria Revit MCP development notes

Cria is a pre-release independent fork of `bimwright/rvt-mcp`. Read [AGENTS.md](AGENTS.md) before making changes and [README.md](README.md) for the current product, protocol, and safety-profile contract.

## Safe validation

Revit 2026 is the required runtime target for v0.1. The other Revit project shells remain for source and CI compatibility.

```powershell
dotnet test tests/RvtMcp.Tests/RvtMcp.Tests.csproj
dotnet build src/server/RvtMcp.Server.csproj -c Release
dotnet build src/plugin-r26/RvtMcp.Plugin.R26.csproj -c Release -p:RvtMcpSkipDeploy=true
```

Always pass `-p:RvtMcpSkipDeploy=true` when building a Revit plugin during ordinary development. Do not run the inherited installer, packaging, registry, or publishing scripts as Cria workflows. Live Revit tests require a previewed, explicitly approved installation and a disposable model; follow [docs/testing/revit-2026-live-smoke.md](docs/testing/revit-2026-live-smoke.md).

Cria intentionally retains the internal `RvtMcp.*` namespaces, assembly names, discovery records, IPC framing, configuration paths, and legacy environment-variable names during v0.1. See [UPSTREAM.md](UPSTREAM.md).
