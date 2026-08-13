# MCP configuration for Claude clients

This guide covers Claude Code CLI, the Claude Code IDE extension, and Claude Desktop.

> **Cria status:** there is no audited Cria installer or production package yet. Build the server from this repository and register it manually. Do not use the inherited `scripts/install.ps1` flow or a versioned `%LOCALAPPDATA%\RvtMcp\server\...` package path for Cria.

The examples below use Revit 2026 and the `safe-authoring` profile. Cria runs as a local process and connects to the Revit add-in on the same workstation. Cria adds no cloud relay. Your MCP client may still send prompts and tool results to its configured model provider, so follow that client's data policy.

## 1. Build the repo-local server

From the repository root:

```powershell
dotnet build src/server/RvtMcp.Server.csproj -c Release
```

The command used by the client is:

```text
dotnet <ABSOLUTE_PATH_TO_REPO>\src\server\bin\Release\net8.0\RvtMcp.Server.dll --target 2026 --profile safe-authoring
```

Replace `<ABSOLUTE_PATH_TO_REPO>` with the full repository path. The Revit add-in must also be present and running. For the current guarded development deployment, see [the Revit 2026 live smoke guide](testing/revit-2026-live-smoke.md).

## 2. Claude Code CLI

Claude Code supports local, project, and user scopes. Options belong before the server name; arguments after `--` are passed to the server command.

```powershell
# Current project only
claude mcp add cria-revit-mcp -- dotnet "<ABSOLUTE_PATH_TO_REPO>\src\server\bin\Release\net8.0\RvtMcp.Server.dll" --target 2026 --profile safe-authoring

# Every project for this user
claude mcp add --scope user cria-revit-mcp -- dotnet "<ABSOLUTE_PATH_TO_REPO>\src\server\bin\Release\net8.0\RvtMcp.Server.dll" --target 2026 --profile safe-authoring

# Shared project entry in .mcp.json
claude mcp add --scope project cria-revit-mcp -- dotnet "<ABSOLUTE_PATH_TO_REPO>\src\server\bin\Release\net8.0\RvtMcp.Server.dll" --target 2026 --profile safe-authoring
```

Useful checks:

```powershell
claude mcp list
claude mcp get cria-revit-mcp
claude mcp remove cria-revit-mcp
```

Use `/mcp` in an active Claude Code session to inspect or reconnect the server.

### Project JSON

The repository includes [.mcp.json.example](../.mcp.json.example). Its shape is:

```json
{
  "mcpServers": {
    "cria-revit-mcp": {
      "command": "dotnet",
      "args": [
        "<ABSOLUTE_PATH_TO_REPO>/src/server/bin/Release/net8.0/RvtMcp.Server.dll",
        "--target",
        "2026",
        "--profile",
        "safe-authoring"
      ]
    }
  }
}
```

Review a project-scoped `.mcp.json` before accepting it because it can start local processes.

## 3. Claude Code IDE extension

The IDE extension uses Claude Code's MCP configuration. Register Cria with the CLI command above, then open `/mcp` in the extension to verify the connection. If the server binary was rebuilt while a session was open, disconnect and reconnect it.

## 4. Claude Desktop

Claude Desktop uses its local MCP configuration file:

| OS | Path |
|---|---|
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |

Add the same repo-local command:

```json
{
  "mcpServers": {
    "cria-revit-mcp": {
      "command": "dotnet",
      "args": [
        "<ABSOLUTE_PATH_TO_REPO>\\src\\server\\bin\\Release\\net8.0\\RvtMcp.Server.dll",
        "--target",
        "2026",
        "--profile",
        "safe-authoring"
      ]
    }
  }
}
```

Use doubled backslashes in JSON on Windows, or use forward slashes. Fully quit and restart Claude Desktop after editing its configuration.

## 5. Safety profiles

The server profile controls which tools Cria publishes:

| Goal | Server arguments |
|---|---|
| Queries only | `--target 2026 --profile read-only` |
| Typed queries and authoring | `--target 2026 --profile safe-authoring` |
| Arbitrary C# and ToolBaker | `--target 2026 --profile developer` |

Use `safe-authoring` unless you deliberately need a different profile. The `developer` profile exposes arbitrary C# execution inside Revit. Client permission rules are useful defense in depth, but they do not replace the server profile.

## 6. Verification and troubleshooting

1. Open Revit 2026 with the Cria add-in loaded.
2. Register the repo-local server.
3. Confirm the server appears connected in `claude mcp list` or `/mcp`.
4. Ask the client to list its Revit tools or call `revit_get_current_view_info`.

The exact tool count depends on the selected profile and toolset configuration. Do not use an inherited fixed count as a health check. All Cria tool names use the `revit_` prefix, and the canonical `cria-revit-mcp` server name stays within Claude's prefixed tool-name limit.

If the server cannot connect to Revit, check the local discovery and log files under `%LOCALAPPDATA%\RvtMcp\`. That compatibility path is retained for now even though the product-facing name is Cria.

## Sources

- [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp)
- [Use Claude Code in an IDE](https://code.claude.com/docs/en/ide-integrations)
- [Connect Claude Desktop to a local MCP server](https://modelcontextprotocol.io/docs/develop/connect-local-servers)
