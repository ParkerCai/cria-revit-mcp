# Upstream attribution

Cria Revit MCP is an independent derivative of [`bimwright/rvt-mcp`](https://github.com/bimwright/rvt-mcp).

The fork started from upstream commit `19b3d14` on August 11, 2026. The upstream work is licensed under Apache License 2.0 and carries the copyright notice in [LICENSE](LICENSE).

Cria's initial changes include:

- MCP C# SDK 2.1 and MCP `2026-07-28` support.
- Explicit stateless Streamable HTTP.
- Cria product and package identity.
- Safe operating profiles with ToolBaker disabled by default.
- Protocol and profile integration tests.

The v0.1 code intentionally retains `RvtMcp.*` internal namespaces, Revit add-in assembly names and paths, named-pipe framing, legacy environment-variable names, and `%LOCALAPPDATA%\RvtMcp` discovery compatibility. This reduces migration risk and allows protocol work to be validated independently of a future installer and storage migration.

Because those compatibility paths are shared, Cria v0.1 and upstream RvtMcp are not supported side by side in the same Revit installation or Windows user profile. The guarded Revit 2026 smoke harness temporarily swaps the payload and restores the exact prior files; a future audited installer will use independent paths.

The product-facing Revit add-in identity is independent: every version-specific manifest uses the name `Cria Revit MCP`, vendor ID `CRIA`, and Cria add-in ID `{c34e4573-49c6-4cf7-a820-7b0dbb874a42}`. The shared ID is deliberate because only one version-specific manifest is loaded by a given Revit host. It is distinct from all inherited upstream add-in IDs.

Cria is not affiliated with or endorsed by BIMwright or Autodesk.
