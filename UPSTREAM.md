# Upstream attribution

Cria Revit MCP is an independent derivative of [`bimwright/rvt-mcp`](https://github.com/bimwright/rvt-mcp).

The fork started from upstream commit `19b3d14` on August 11, 2026. The upstream work is licensed under Apache License 2.0 and carries the copyright notice in [LICENSE](LICENSE).

Cria's initial changes include:

- MCP C# SDK 2.1 and MCP `2026-07-28` support.
- Explicit stateless Streamable HTTP.
- Cria product and package identity.
- Safe operating profiles with ToolBaker disabled by default.
- Protocol and profile integration tests.

The v0.1 code intentionally retains `RvtMcp.*` internal namespaces, Revit add-in assembly names, named-pipe framing, and `%LOCALAPPDATA%\RvtMcp` discovery compatibility. This reduces migration risk and allows protocol work to be validated independently of a future installer and storage migration.

Cria is not affiliated with or endorsed by BIMwright or Autodesk.
