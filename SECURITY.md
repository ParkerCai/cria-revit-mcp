# Security policy

## Supported versions

Cria is pre-release software. Security fixes currently target the latest `master` branch and the latest published Cria release, when one exists.

## Trust boundary

Cria is local-only by design:

- MCP stdio is a child-process channel.
- Streamable HTTP binds to loopback.
- Revit IPC uses loopback TCP for Revit 2022-2024 and local named pipes for Revit 2025-2027.
- Discovery files and logs stay under the current Windows user profile.

Local-only does not mean harmless. Any process running as the same Windows user may be inside part of this trust boundary.

## Safety profiles

- `read-only` removes write-capable toolsets.
- `safe-authoring` is the default and excludes deletion and arbitrary C#.
- `developer` enables ToolBaker and `revit_send_code_to_revit` but does not enable deletion unless separately requested.

`revit_send_code_to_revit` compiles and runs arbitrary C# inside Revit. Use it only with trusted prompts, clients, and models. A confirmation dialog cannot make unreviewed code safe.

## Existing mitigations

- per-session authentication tokens for Revit IPC;
- best-effort user-only ACLs on discovery files;
- schema validation before handler dispatch;
- local transport binding by default;
- request-size and rate limits on socket transport;
- secret masking and path sanitization for model-facing errors;
- opt-in adaptive bake, code-body cache, and TTL journal;
- safety profiles that reduce the default tool surface.

No safeguard replaces backups, Revit worksharing controls, transactions, or testing on a disposable model.

## Reporting a vulnerability

Do not open a public issue for a suspected authentication bypass, privilege escalation, arbitrary-code path, credential leak, or other sensitive vulnerability.

Use GitHub's private vulnerability reporting for [ParkerCai/cria-revit-mcp](https://github.com/ParkerCai/cria-revit-mcp/security/advisories/new). If private reporting is unavailable, contact the maintainer through the address on the Git commit history without including live project data.

Include the Cria version or commit, Revit year, reproduction steps, impact, and whether user interaction is required. Coordinate disclosure until a fix is available.
