# MCP configuration for OpenCode and Kilo

This guide covers current OpenCode V2 and Kilo Code CLI configuration for a local Cria server.

> **Cria status:** there is no audited Cria installer or production package yet. Build the server from this repository and register it manually. Do not use the inherited `scripts/install.ps1` flow or a versioned `%LOCALAPPDATA%\RvtMcp\server\...` package path for Cria.

The examples below use Revit 2026 and the `safe-authoring` profile. Cria runs as a local stdio process and connects to the Revit add-in on the same workstation. Cria adds no cloud relay. Your MCP client may still send prompts and tool results to its configured model provider, so follow that client's data policy.

For Claude clients, see [the Claude configuration guide](mcp-config-claude-clients.md). For Codex, see [the Codex configuration guide](mcp-config-codex.md).

## 1. Build the repo-local server

From the repository root:

```powershell
dotnet build src/server/RvtMcp.Server.csproj -c Release
```

Both clients should start this command:

```text
dotnet <ABSOLUTE_PATH_TO_REPO>\src\server\bin\Release\net8.0\RvtMcp.Server.dll --target 2026 --profile safe-authoring
```

Replace `<ABSOLUTE_PATH_TO_REPO>` with the full repository path. The Revit add-in must also be present and running. For the current guarded development deployment, see [the Revit 2026 live smoke guide](testing/revit-2026-live-smoke.md).

## 2. OpenCode V2

OpenCode V2 stores servers under `mcp.servers`. This differs from older OpenCode configurations that placed server names directly under `mcp`.

Add this to an OpenCode configuration file such as a project-level `opencode.json`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "cria-revit-mcp": {
        "type": "local",
        "command": [
          "dotnet",
          "C:/absolute/path/to/cria-revit-mcp/src/server/bin/Release/net8.0/RvtMcp.Server.dll",
          "--target",
          "2026",
          "--profile",
          "safe-authoring"
        ],
        "disabled": false,
        "timeout": 75000
      }
    }
  }
}
```

Use forward slashes in the Windows path to avoid JSON escaping mistakes. The timeout is longer than Cria's 60-second Revit request timeout, so the client does not abandon a call first.

OpenCode V2 also supports CLI registration:

```powershell
opencode2 mcp add cria-revit-mcp -- dotnet "<ABSOLUTE_PATH_TO_REPO>\src\server\bin\Release\net8.0\RvtMcp.Server.dll" --target 2026 --profile safe-authoring
opencode2 mcp list
```

If your installed executable is named differently, run its `mcp --help` command and use the JSON configuration above as the source of truth.

## 3. Kilo Code CLI

Kilo stores servers directly under the top-level `mcp` key. A project can use `kilo.jsonc` or `.kilo/kilo.jsonc`; the usual global path is `~/.config/kilo/kilo.jsonc`.

```jsonc
{
  "$schema": "https://app.kilo.ai/config.json",
  "mcp": {
    "cria-revit-mcp": {
      "type": "local",
      "command": [
        "dotnet",
        "C:/absolute/path/to/cria-revit-mcp/src/server/bin/Release/net8.0/RvtMcp.Server.dll",
        "--target",
        "2026",
        "--profile",
        "safe-authoring"
      ],
      "enabled": true,
      "timeout": 75000
    }
  }
}
```

Use Kilo's MCP commands to add interactively or verify the entry:

```powershell
kilo mcp add cria-revit-mcp
kilo mcp list
```

The Kilo settings UI can also add a Local (stdio) server. Supply `dotnet` as the command and the array entries after it as arguments.

## 4. Important format differences

| Setting | OpenCode V2 | Kilo Code CLI |
|---|---|---|
| Server map | `mcp.servers` | `mcp` |
| Local command | String array | String array |
| Enabled state | `disabled: false` | `enabled: true` |
| Timeout | Milliseconds | Milliseconds |

Do not copy a Claude `mcpServers` block into either client. Do not copy the Kilo `mcp` shape into OpenCode V2 without adding the `servers` level.

## 5. Safety profiles and catalog size

The server profile controls which tools Cria publishes:

| Goal | Server arguments |
|---|---|
| Queries only | `--target 2026 --profile read-only` |
| Typed queries and authoring | `--target 2026 --profile safe-authoring` |
| Arbitrary C# and ToolBaker | `--target 2026 --profile developer` |

Use `safe-authoring` unless you deliberately need a different profile. The `developer` profile exposes arbitrary C# execution inside Revit. Client permission rules are useful defense in depth, but they do not replace the server profile.

Cria has a large tool catalog. The exact count depends on the selected profile and toolset configuration. If a client has context pressure, prefer `read-only` or an intentionally narrow `--toolsets` list rather than relying on an inherited fixed count.

## 6. Verification and troubleshooting

1. Open Revit 2026 with the Cria add-in loaded.
2. Add the repo-local Release server.
3. Confirm it appears in `opencode2 mcp list` or `kilo mcp list`.
4. Ask the client to list its Revit tools or call `revit_get_current_view_info`.

This guide intentionally uses local stdio. Do not replace the command with a public HTTP URL. Cria's optional HTTP transport is loopback-only and is not a cloud deployment path.

If the server cannot connect to Revit, check the local discovery and log files under `%LOCALAPPDATA%\RvtMcp\`. That compatibility path is retained for now even though the product-facing name is Cria.

## Sources

- [OpenCode V2 MCP servers](https://opencode.ai/v2/docs/mcp-servers)
- [OpenCode configuration](https://opencode.ai/docs/config/)
- [Using MCP in Kilo Code](https://kilo.ai/docs/automate/mcp/using-in-kilo-code)
- [Kilo Code CLI reference](https://kilo.ai/docs/code-with-ai/platforms/cli-reference)
