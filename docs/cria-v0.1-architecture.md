# Cria v0.1 architecture

## Scope

Cria v0.1 is a local-only MCP gateway for a live Revit 2026 desktop process. Model data and IPC remain on the workstation. Revit 2022–2027 project shells are retained, but only Revit 2026 is an initial runtime target.

## Process boundary

```text
MCP client
  -> stdio or localhost Streamable HTTP
Cria server (.NET 8, MCP SDK 2.1)
  -> authenticated named pipe
Revit 2026 add-in
  -> ExternalEvent and serialized UI-thread execution
Revit API and Document transactions
```

The MCP transport is stateless. Revit is not. The running process, active document, UI thread, transactions, selection, and model version remain application state managed behind the MCP boundary.

## Protocol behavior implemented

- Modern clients use `server/discover` and MCP version `2026-07-28`.
- Modern requests do not use `initialize` or `Mcp-Session-Id`.
- HTTP sets `Stateless = true` explicitly.
- The server binds to `127.0.0.1` and rejects non-loopback Host headers.
- The standalone legacy `/sse` route is absent.
- SDK 2.1 retains down-level client negotiation during migration.
- Server identity is `cria-revit-mcp` version `0.1.0`.

## Profiles implemented

- `read-only`: removes every toolset classified as write-capable.
- `safe-authoring`: default; includes typed create and modify surfaces, excludes delete and ToolBaker.
- `developer`: adds ToolBaker and arbitrary C# execution, but does not add delete by default.

`--toolsets` is an explicit advanced override. `--toolsets all` exposes every registered toolset.

## Compatibility retained for v0.1

- Internal `RvtMcp.*` namespaces and assembly names.
- Revit add-in wire commands and DTOs.
- Existing authenticated discovery records and named-pipe transport.
- Existing tool names beginning with `revit_`.
- Multi-version source projects where maintenance remains low.

## Required before the first installable release

1. Replace global target switching with request-safe routing or pin the packaged v0.1 server to Revit 2026.
2. Add idempotency keys for model mutations so network retries cannot duplicate work.
3. Implement fixed confirmation rules for destructive and high-volume operations using MCP multi-round-trip requests where the client supports them.
4. Add a Cria-specific installer, add-in identity, storage paths, discovery schema, and rollback process.
5. Add live Revit 2026 smoke tests for raster-plan modeling, model auditing, and documentation/sheet workflows.
6. Decide whether localhost HTTP needs a per-launch bearer token in addition to loopback and Host restrictions.
