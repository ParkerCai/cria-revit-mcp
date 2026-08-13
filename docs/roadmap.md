# Cria roadmap

This is direction, not a release commitment.

## v0.1 foundation

- MCP C# SDK 2.1 with MCP `2026-07-28` support.
- Stateless discovery and stateless Streamable HTTP on loopback.
- Default `safe-authoring` profile without deletion or arbitrary C#.
- Local-only Revit IPC and workstation data storage.
- Revit 2026 runtime target with the inherited 2022-2027 source matrix preserved.
- Provider-neutral tool-routing benchmark.

## Next

- Live Revit 2026 smoke tests for raster-plan modeling, model auditing, documentation, sheets, and general automation.
- Preview and confirmation contracts for destructive or high-impact operations.
- Better progress and cancellation behavior for long Revit operations.
- Tool-surface review focused on smaller context cost and clearer routing.
- A test-only MCP conformance host with the official diagnostic fixture surface.
- Audited Cria installer and packaging; inherited upstream installers must not be used as Cria releases.
- Authenticode-signed release add-in binaries so Revit can verify the publisher; local development builds remain unsigned.
- Clear storage migration away from retained upstream compatibility paths when it can be done safely.

## Later

- Optional organization-configurable policy profiles while preserving a simple local default.
- Signed or otherwise integrity-checked personal baked tools.
- Broader runtime validation for preserved Revit versions when maintainers have access to them.
- Release automation and MCP registry metadata after installer and package identities are stable.

## Explicit non-goals for v0.1

- cloud relay or remote model storage;
- Python or IronPython execution inside Revit;
- Revit Viewer support;
- a complete Family Editor authoring suite;
- automatic execution of unreviewed generated C#;
- requiring Revit versions other than 2026 for local development.
