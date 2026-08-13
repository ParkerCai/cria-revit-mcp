# MCP configuration for Codex clients

This guide covers Codex CLI, the Codex IDE extension, and desktop clients that use the same local Codex host configuration.

> **Cria status:** there is no audited Cria installer or production package yet. Build the server from this repository and register it manually. Do not use the inherited `scripts/install.ps1` flow or a versioned `%LOCALAPPDATA%\RvtMcp\server\...` package path for Cria.

The examples below use Revit 2026 and the `safe-authoring` profile. Cria runs as a local process and connects to the Revit add-in on the same workstation. Cria adds no cloud relay. Your Codex or ChatGPT client may still send prompts and tool results to its configured model provider, so follow the client's data policy.

For Claude clients, see [the Claude configuration guide](mcp-config-claude-clients.md). For OpenCode and Kilo, see [the OpenCode/Kilo guide](mcp-config-opencode-kilo.md).

## 1. Build the repo-local server

From the repository root:

```powershell
dotnet build src/server/RvtMcp.Server.csproj -c Release
```

The command registered with Codex is:

```text
dotnet <ABSOLUTE_PATH_TO_REPO>\src\server\bin\Release\net8.0\RvtMcp.Server.dll --target 2026 --profile safe-authoring
```

Replace `<ABSOLUTE_PATH_TO_REPO>` with the full repository path. The Revit add-in must also be present and running. For the current guarded development deployment, see [the Revit 2026 live smoke guide](testing/revit-2026-live-smoke.md).

## 2. Register with the Codex CLI

Official Codex documentation supports local stdio MCP servers through `codex mcp add`:

```powershell
codex mcp add cria-revit-mcp -- dotnet "<ABSOLUTE_PATH_TO_REPO>\src\server\bin\Release\net8.0\RvtMcp.Server.dll" --target 2026 --profile safe-authoring
```

The `--` separates Codex options from the local process and its arguments.

Useful checks:

```powershell
codex mcp list
codex mcp remove cria-revit-mcp
codex mcp --help
```

Use `/mcp` in an active Codex session to inspect connected servers.

## 3. Configure `config.toml` manually

Codex stores MCP configuration in `config.toml`. The user-level file is `%USERPROFILE%\.codex\config.toml` on Windows and `~/.codex/config.toml` on macOS or Linux. Trusted projects may also use `.codex/config.toml`.

Use forward slashes in the Windows path to avoid TOML escaping mistakes:

```toml
[mcp_servers.cria-revit-mcp]
command = "dotnet"
args = [
  "C:/absolute/path/to/cria-revit-mcp/src/server/bin/Release/net8.0/RvtMcp.Server.dll",
  "--target",
  "2026",
  "--profile",
  "safe-authoring"
]
```

The ChatGPT desktop app, Codex CLI, and the Codex IDE extension can share MCP configuration when they use the same Codex host. Restart or reconnect the local server after editing the file.

## 4. Safety profiles

The server profile controls which tools Cria publishes:

| Goal | Server arguments |
|---|---|
| Queries only | `--target 2026 --profile read-only` |
| Typed queries and authoring | `--target 2026 --profile safe-authoring` |
| Arbitrary C# and ToolBaker | `--target 2026 --profile developer` |

Use `safe-authoring` unless you deliberately need a different profile. The `developer` profile exposes arbitrary C# execution inside Revit. Codex-side tool approvals or allowlists are useful defense in depth, but they do not replace the server profile.

## 5. Verification and troubleshooting

1. Open Revit 2026 with the Cria add-in loaded.
2. Register the repo-local Release server.
3. Confirm it appears in `codex mcp list` or `/mcp`.
4. Ask Codex to list its Revit tools or call `revit_get_current_view_info`.

The exact tool count depends on the selected profile and toolset configuration. Do not use an inherited fixed count as a health check.

If the server cannot connect to Revit, check the local discovery and log files under `%LOCALAPPDATA%\RvtMcp\`. That compatibility path is retained for now even though the product-facing name is Cria.

## Sources

- [Model Context Protocol for Codex and ChatGPT](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)
- [Codex configuration basics](https://learn.chatgpt.com/docs/config-file/config-basic)
- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
