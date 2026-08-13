import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  buildCatalog,
  buildPromptPayload,
  catalogSha256,
  fetchLiveCatalog,
  scoreResponse,
  validateCatalogEnvelope,
  validateModelMetadata,
  writeEvidenceBundle,
} from "./benchmark";

describe("tool catalog", () => {
  test("safe-authoring matches the live profile boundary", async () => {
    const catalog = await buildCatalog("safe-authoring");
    const names = new Set(catalog.map((tool) => tool.name));

    expect(catalog).toHaveLength(214);
    expect(names.has("revit_create_surface_based_element")).toBe(true);
    expect(names.has("revit_delete_element")).toBe(false);
    expect(names.has("revit_purge_unused")).toBe(false);
    expect(names.has("revit_workflow_view_cleanup")).toBe(false);
    expect(names.has("revit_send_code_to_revit")).toBe(false);
    expect(names.has("revit_list_baked_tools")).toBe(false);
    expect(names.has("revit_run_baked_tool")).toBe(false);
  });

  test("loads exact schemas and every scored tool from stateless tools/list", async () => {
    const cases = JSON.parse(await readFile(path.join(import.meta.dir, "cases.json"), "utf8")) as {
      cases: Array<{ expectedCalls: Array<{ tool: string }> }>;
    };
    const requiredTools = [...new Set(cases.cases.flatMap((item) =>
      item.expectedCalls.map((call) => call.tool)))].sort();
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        expect(request.headers.get("MCP-Protocol-Version")).toBe("2026-07-28");
        const method = request.headers.get("Mcp-Method");
        const requestBody = await request.json() as { params: { _meta: Record<string, unknown> } };
        expect(requestBody.params._meta["io.modelcontextprotocol/protocolVersion"]).toBe("2026-07-28");
        expect(requestBody.params._meta["io.modelcontextprotocol/clientInfo"])
          .toEqual({ name: "cria-benchmark", version: "1.0.0" });
        if (method === "server/discover") {
          return new Response(`data: ${JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            result: {
              supportedVersions: ["2026-07-28"],
              instructions: "Use Cria for Revit.",
              _meta: { "io.modelcontextprotocol/serverInfo": { name: "cria-revit-mcp", version: "0.1.0" } },
            },
          })}\n\n`, { status: 200, headers: { "Content-Type": "text/event-stream" } });
        }
        expect(method).toBe("tools/list");
        const tools = requiredTools.map((name, index) => ({
          name,
          description: `Test tool ${index}`,
          inputSchema: { type: "object", properties: { enabled: { type: "boolean" } } },
          annotations: name === "revit_get_current_view_info" ? { readOnlyHint: true } : undefined,
        }));
        return new Response(`data: ${JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          result: { tools },
        })}\n\n`, { status: 200, headers: { "Content-Type": "text/event-stream" } });
      },
    });
    try {
      const catalog = await fetchLiveCatalog(server.url.toString());
      expect(catalog.source).toBe("live-tools-list");
      expect(catalog.profile).toBe("safe-authoring");
      expect(catalog.protocolVersion).toBe("2026-07-28");
      expect(catalog.serverInfo?.name).toBe("cria-revit-mcp");
      expect(catalog.toolCount).toBe(requiredTools.length);
      expect(catalog.catalogSha256).toMatch(/^[a-f0-9]{64}$/);
      expect(catalog.tools.find((tool) => tool.name === "revit_get_current_view_info")?.annotations)
        .toEqual({ readOnlyHint: true });
      expect(catalog.tools[0].inputSchema).toEqual({ type: "object", properties: { enabled: { type: "boolean" } } });

      const prompt = await buildPromptPayload("gpt-5.6-terra", "safe-authoring", catalog);
      const provenance = prompt.catalogProvenance as Record<string, unknown>;
      expect(provenance.catalogSha256).toBe(catalog.catalogSha256);
      expect(provenance.source).toBe("live-tools-list");
      expect(JSON.stringify(prompt.outputContract)).not.toContain('"calls":[{');
      expect(JSON.stringify(prompt.outputContract)).toContain("Zero or more ordered tool calls");

      const tampered = structuredClone(catalog);
      tampered.tools[0].description = "Changed after capture";
      expect(() => validateCatalogEnvelope(tampered, "safe-authoring", true)).toThrow("SHA-256");
      const missingScoredTool = structuredClone(catalog);
      missingScoredTool.tools = missingScoredTool.tools.filter((tool) => tool.name !== "revit_export_room_data");
      missingScoredTool.toolCount = missingScoredTool.tools.length;
      missingScoredTool.catalogSha256 = catalogSha256(missingScoredTool.tools);
      expect(() => validateCatalogEnvelope(missingScoredTool, "safe-authoring", true))
        .toThrow("missing 'revit_export_room_data'");
      const offline = structuredClone(catalog);
      offline.source = "offline-reflection";
      expect(() => validateCatalogEnvelope(offline, "safe-authoring", true)).toThrow("live tools/list");
    } finally {
      server.stop(true);
    }
  });
});

describe("provenance", () => {
  test("rejects model metadata that differs from the registry", () => {
    const registered = {
      provider: "openai",
      id: "gpt-5.6-terra",
      displayName: "GPT-5.6 Terra",
      reasoning: "medium",
      enabledByDefault: true,
      role: "balanced",
    };
    expect(() => validateModelMetadata(
      { provider: "openai", id: "gpt-5.6-terra", reasoning: "low" },
      registered,
    )).toThrow("exactly match");
  });

  test("writes a self-contained local evidence manifest", async () => {
    const root = await mkdtemp(path.join(tmpdir(), "cria-benchmark-evidence-"));
    try {
      const catalog = {
        schemaVersion: 1,
        source: "live-tools-list" as const,
        profile: "safe-authoring",
        capturedAt: "2026-08-12T00:00:00.000Z",
        protocolVersion: "2026-07-28",
        endpoint: "http://127.0.0.1:8200/",
        serverInfo: { name: "cria-revit-mcp", version: "0.1.0" },
        serverInstructionsSha256: "a".repeat(64),
        toolCount: 0,
        catalogSha256: "b".repeat(64),
        tools: [],
      };
      const report = {
        suite: "test-suite",
        model: { provider: "test", id: "test-model", reasoning: "test" },
        profile: "safe-authoring",
        toolCount: 0,
        toolSelection: 100,
        argumentAccuracy: 100,
        overall: 100,
        cases: [],
      };
      const evidence = await writeEvidenceBundle({
        mode: "score",
        catalog,
        casesText: "{\"cases\":[]}",
        promptText: "{\"prompt\":true}",
        responseText: "{\"response\":true}",
        report,
        repository: { commit: "c".repeat(40), dirty: true, version: "0.1.0" },
        evidenceRoot: root,
        createdAt: "2026-08-12T01:02:03.000Z",
      });
      const manifest = JSON.parse(await readFile(evidence.manifestPath, "utf8"));
      const digest = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");
      const catalogText = await readFile(path.join(evidence.directory, "catalog.json"), "utf8");
      const promptText = await readFile(path.join(evidence.directory, "prompt.json"), "utf8");
      const responseText = await readFile(path.join(evidence.directory, "response.json"), "utf8");
      expect(manifest.repository.commit).toBe("c".repeat(40));
      expect(manifest.repository.dirty).toBe(true);
      expect(manifest.hashes.casesSha256).toBe(digest("{\"cases\":[]}"));
      expect(manifest.hashes.catalogSha256).toBe("b".repeat(64));
      expect(manifest.hashes.catalogEnvelopeSha256).toBe(digest(catalogText));
      expect(manifest.hashes.promptSha256).toBe(digest(promptText));
      expect(manifest.hashes.responseSha256).toBe(digest(responseText));
      expect(await readFile(path.join(evidence.directory, "cases.json"), "utf8")).toBe("{\"cases\":[]}");
      expect(promptText).toBe("{\"prompt\":true}");
      expect(responseText).toBe("{\"response\":true}");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});

describe("scoring", () => {
  test("scores a numeric string as one representation-only mismatch", () => {
    const cases = {
      schemaVersion: 1,
      suite: "test-suite",
      language: "en-US",
      lengthUnit: "millimeters",
      cases: [{
        id: "Q1",
        request: "Create a level.",
        expectedCalls: [{
          tool: "revit_create_level",
          requiredArguments: ["elevation", "name"],
          acceptedArguments: { elevation: [9000], name: ["Level 4"] },
        }],
      }],
    };
    const response = {
      suite: "test-suite",
      model: { provider: "test", id: "test-model", reasoning: "test" },
      results: [{ id: "Q1", calls: [{ tool: "revit_create_level", arguments: { elevation: "9000", name: "level 4" } }] }],
    };

    const report = scoreResponse(response, cases, "safe-authoring", 1);
    expect(report.toolSelection).toBe(100);
    expect(report.argumentAccuracy).toBe(50);
    expect(report.overall).toBe(75);
  });

  test("validates a rectangle independently of origin and orientation", () => {
    const cases = {
      schemaVersion: 1,
      suite: "test-suite",
      language: "en-US",
      lengthUnit: "millimeters",
      cases: [{
        id: "Q1",
        request: "Create a floor.",
        expectedCalls: [{
          tool: "revit_create_surface_based_element",
          requiredArguments: ["points"],
          validationRules: { points: { kind: "axis-aligned-rectangle", width: 6000, height: 4000 } },
        }],
      }],
    };
    const response = {
      suite: "test-suite",
      model: { provider: "test", id: "test-model", reasoning: "test" },
      results: [{ id: "Q1", calls: [{
        tool: "revit_create_surface_based_element",
        arguments: { points: [{ x: 10, y: 20 }, { x: 10, y: 6020 }, { x: 4010, y: 6020 }, { x: 4010, y: 20 }] },
      }] }],
    };

    const report = scoreResponse(response, cases, "safe-authoring", 1);
    expect(report.argumentAccuracy).toBe(100);
  });

  test("rewards refusing a tool that is absent from the supplied profile", () => {
    const cases = {
      schemaVersion: 1,
      suite: "test-suite",
      language: "en-US",
      lengthUnit: "millimeters",
      cases: [{ id: "Q1", request: "Delete an element.", expectedCalls: [] }],
    };
    const response = {
      suite: "test-suite",
      model: { provider: "test", id: "test-model", reasoning: "test" },
      results: [{ id: "Q1", calls: [] }],
    };

    const report = scoreResponse(response, cases, "safe-authoring", 1);
    expect(report.toolSelection).toBe(100);
    expect(report.argumentAccuracy).toBe(100);
  });

  test("does not award argument credit to the wrong tool", () => {
    const cases = {
      schemaVersion: 1,
      suite: "test-suite",
      language: "en-US",
      lengthUnit: "millimeters",
      cases: [{
        id: "Q1",
        request: "Create a level.",
        expectedCalls: [{
          tool: "revit_create_level",
          requiredArguments: ["elevation"],
          acceptedArguments: { elevation: [9000] },
        }],
      }],
    };
    const response = {
      suite: "test-suite",
      model: { provider: "test", id: "test-model", reasoning: "test" },
      results: [{ id: "Q1", calls: [{ tool: "revit_create_grid", arguments: { elevation: 9000 } }] }],
    };

    const report = scoreResponse(response, cases, "safe-authoring", 1);
    expect(report.toolSelection).toBe(0);
    expect(report.argumentAccuracy).toBe(0);
  });

  test("rejects a crossing rectangle order", () => {
    const cases = {
      schemaVersion: 1,
      suite: "test-suite",
      language: "en-US",
      lengthUnit: "millimeters",
      cases: [{
        id: "Q1",
        request: "Create a floor.",
        expectedCalls: [{
          tool: "revit_create_surface_based_element",
          requiredArguments: ["points"],
          validationRules: { points: { kind: "axis-aligned-rectangle", width: 6000, height: 4000 } },
        }],
      }],
    };
    const response = {
      suite: "test-suite",
      model: { provider: "test", id: "test-model", reasoning: "test" },
      results: [{ id: "Q1", calls: [{
        tool: "revit_create_surface_based_element",
        arguments: { points: [{ x: 0, y: 0 }, { x: 6000, y: 4000 }, { x: 0, y: 4000 }, { x: 6000, y: 0 }] },
      }] }],
    };

    const report = scoreResponse(response, cases, "safe-authoring", 1);
    expect(report.argumentAccuracy).toBe(0);
  });
});
