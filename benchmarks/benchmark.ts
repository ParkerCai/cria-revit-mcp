import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

export type ToolCatalogEntry = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  annotations?: Record<string, unknown>;
  toolset: string;
};

export type CatalogEnvelope = {
  schemaVersion: number;
  source: "live-tools-list" | "offline-reflection";
  profile: string;
  capturedAt: string;
  protocolVersion?: string;
  endpoint?: string;
  serverInfo?: Record<string, unknown>;
  serverInstructionsSha256?: string;
  toolCount: number;
  catalogSha256: string;
  tools: ToolCatalogEntry[];
};

type ExpectedCall = {
  tool: string;
  requiredArguments?: string[];
  acceptedArguments?: Record<string, unknown[]>;
  derivedArguments?: Record<string, string>;
  semanticArguments?: Record<string, string>;
  validationRules?: Record<string, Record<string, unknown>>;
};

type BenchmarkCase = {
  id: string;
  request: string;
  expectedCalls: ExpectedCall[];
};

type CasesFile = {
  schemaVersion: number;
  suite: string;
  language: string;
  lengthUnit: string;
  cases: BenchmarkCase[];
};

type ModelRegistry = {
  schemaVersion: number;
  suite: string;
  models: Array<{
    provider: string;
    id: string;
    displayName: string;
    reasoning: string;
    enabledByDefault: boolean;
    role: string;
  }>;
};

type RegisteredModel = ModelRegistry["models"][number];

type ModelResponse = {
  suite: string;
  model: { provider: string; id: string; reasoning: string };
  results: Array<{
    id: string;
    calls: Array<{ tool: string; arguments: Record<string, unknown> }>;
  }>;
};

type CaseScore = {
  id: string;
  expectedTools: string[];
  actualTools: string[];
  toolScore: number;
  argumentScore: number;
  notes: string[];
};

export type ScoreReport = {
  suite: string;
  model: ModelResponse["model"];
  profile: string;
  toolCount: number;
  toolSelection: number;
  argumentAccuracy: number;
  overall: number;
  cases: CaseScore[];
};

type RepositoryMetadata = {
  commit: string;
  dirty: boolean;
  version: string;
};

type EvidenceHashes = {
  casesSha256: string;
  catalogSha256: string;
  catalogEnvelopeSha256: string;
  promptSha256: string;
  responseSha256: string;
  reportSha256: string;
};

type EvidenceManifest = {
  schemaVersion: 1;
  suite: string;
  createdAt: string;
  mode: "score" | "run";
  repository: RepositoryMetadata;
  model: ModelResponse["model"];
  profile: string;
  catalog: Omit<CatalogEnvelope, "tools">;
  hashes: EvidenceHashes;
  scores: {
    toolSelection: number;
    argumentAccuracy: number;
    overall: number;
  };
  files: {
    catalog: "catalog.json";
    cases: "cases.json";
    prompt: "prompt.json";
    response: "response.json";
    report: "report.md";
    manifest: "manifest.json";
  };
};

const benchmarksDir = import.meta.dir;
const repoRoot = path.resolve(benchmarksDir, "..");
const defaultGoldenPath = path.join(repoRoot, "tests", "RvtMcp.Tests", "Golden", "tools-list.json");
const programPath = path.join(repoRoot, "src", "server", "Program.cs");
const toolsetFilterPath = path.join(repoRoot, "src", "server", "ToolsetFilter.cs");
const casesPath = path.join(benchmarksDir, "cases.json");
const modelsPath = path.join(benchmarksDir, "models.json");
const localOutputDir = path.join(benchmarksDir, ".local");

const routingSuiteRequiredTools = (() => {
  const cases = JSON.parse(readFileSync(casesPath, "utf8")) as CasesFile;
  return [...new Set(cases.cases.flatMap((benchmarkCase) =>
    benchmarkCase.expectedCalls.map((call) => call.tool)))].sort();
})();

function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function serializeJson(value: unknown): string {
  return JSON.stringify(value, null, 2) + "\n";
}

export function catalogSha256(tools: ToolCatalogEntry[]): string {
  return sha256(stable(tools.map(({ name, description, inputSchema, annotations }) => ({
    name,
    description,
    inputSchema,
    annotations: annotations ?? null,
  }))));
}

function decodeCSharpString(value: string): string {
  return value
    .replace(/\\"/g, '"')
    .replace(/\\r/g, "\r")
    .replace(/\\n/g, "\n")
    .replace(/\\t/g, "\t")
    .replace(/\\\\/g, "\\");
}

function parseStringLiterals(expression: string): string {
  return [...expression.matchAll(/"((?:\\.|[^"\\])*)"/g)]
    .map((match) => decodeCSharpString(match[1]))
    .join("");
}

function parseStringArray(source: string, name: string): string[] {
  const expression = new RegExp(
    `public\\s+static\\s+readonly\\s+string\\[\\]\\s+${name}\\s*=\\s*\\{([\\s\\S]*?)\\};`,
  ).exec(source)?.[1];
  if (!expression) throw new Error(`Could not find ToolsetFilter.${name}.`);
  return [...expression.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
}

function enabledToolsets(profile: string, toolsetSource: string): Set<string> {
  const defaults = parseStringArray(toolsetSource, "DefaultOn");
  const writeCapable = new Set(parseStringArray(toolsetSource, "WriteCapable"));

  if (profile === "safe-authoring") return new Set(defaults);
  if (profile === "developer") return new Set([...defaults, "toolbaker"]);
  if (profile === "read-only") return new Set(defaults.filter((name) => !writeCapable.has(name)));
  if (profile === "all") return new Set(parseStringArray(toolsetSource, "KnownToolsets"));
  throw new Error(`Unknown profile '${profile}'. Use read-only, safe-authoring, developer, or all.`);
}

function parseProgramToolMetadata(programSource: string): Map<string, { description: string; toolset: string }> {
  const metadata = new Map<string, { description: string; toolset: string }>();
  const toolsetBlocks = programSource.matchAll(
    /\[McpServerToolType,\s*Toolset\("([^"]+)"\)\]([\s\S]*?)(?=\[McpServerToolType,\s*Toolset\("|\s*$)/g,
  );

  for (const block of toolsetBlocks) {
    const toolset = block[1];
    const body = block[2];
    const toolAttributes = body.matchAll(
      /\[McpServerTool\(([\s\S]*?)\),\s*System\.ComponentModel\.Description\(([\s\S]*?)\)\]\s*public/g,
    );
    for (const attribute of toolAttributes) {
      const name = /\bName\s*=\s*"([^"]+)"/.exec(attribute[1])?.[1];
      if (!name) continue;
      metadata.set(name, {
        description: parseStringLiterals(attribute[2]),
        toolset,
      });
    }
  }
  return metadata;
}

function requireRoutingProfile(profile: string): void {
  if (profile !== "safe-authoring") {
    throw new Error("cria-tool-routing-v1 is defined only for the safe-authoring profile.");
  }
}

export async function buildCatalog(profile = "safe-authoring"): Promise<ToolCatalogEntry[]> {
  requireRoutingProfile(profile);
  const [goldenText, programSource, toolsetSource] = await Promise.all([
    readFile(defaultGoldenPath, "utf8"),
    readFile(programPath, "utf8"),
    readFile(toolsetFilterPath, "utf8"),
  ]);
  const golden = JSON.parse(goldenText) as {
    tools: Array<{ name: string; inputSchema: Record<string, unknown> }>;
  };
  const programMetadata = parseProgramToolMetadata(programSource);
  const enabled = enabledToolsets(profile, toolsetSource);

  const catalog = golden.tools
    .map((tool) => {
      const metadata = programMetadata.get(tool.name);
      if (!metadata) throw new Error(`No Program.cs metadata found for ${tool.name}.`);
      return {
        name: tool.name,
        description: metadata.description,
        inputSchema: tool.inputSchema,
        toolset: metadata.toolset,
      };
    })
    .filter((tool) => enabled.has(tool.toolset))
    .sort((left, right) => left.name.localeCompare(right.name));

  if (catalog.some((tool) => !tool.description.trim())) {
    throw new Error("The catalog contains an empty tool description.");
  }

  const expectedNames = new Set(
    [...programMetadata.entries()]
      .filter(([, metadata]) => enabled.has(metadata.toolset))
      .map(([name]) => name),
  );
  const actualNames = new Set(catalog.map((tool) => tool.name));
  const missing = [...expectedNames].filter((name) => !actualNames.has(name));
  const unexpected = [...actualNames].filter((name) => !expectedNames.has(name));
  if (missing.length || unexpected.length) {
    throw new Error(`Offline snapshot and Program.cs differ. Missing: ${missing.join(", ") || "none"}; unexpected: ${unexpected.join(", ") || "none"}.`);
  }
  return catalog;
}

function parseJsonRpcBody(body: string): Record<string, unknown> {
  const dataLine = body.split(/\r?\n/).find((line) => line.startsWith("data:"));
  const payload = dataLine ? dataLine.slice("data:".length).trim() : body.trim();
  const parsed = JSON.parse(payload) as Record<string, unknown>;
  if (parsed.error) throw new Error(`MCP error: ${JSON.stringify(parsed.error)}`);
  return parsed;
}

async function callStateless(serverUrl: string, method: string, params: Record<string, unknown>): Promise<{
  rpc: Record<string, unknown>;
  sessionId: string | null;
}> {
  const response = await fetch(serverUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream",
      "MCP-Protocol-Version": "2026-07-28",
      "Mcp-Method": method,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: Date.now(),
      method,
      params: {
        ...params,
        _meta: {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientInfo": { name: "cria-benchmark", version: "1.0.0" },
          "io.modelcontextprotocol/clientCapabilities": {},
        },
      },
    }),
  });
  const body = await response.text();
  if (!response.ok) throw new Error(`${method} returned HTTP ${response.status}: ${body}`);
  return { rpc: parseJsonRpcBody(body), sessionId: response.headers.get("Mcp-Session-Id") };
}

function validateSafeCatalog(tools: ToolCatalogEntry[]): void {
  const names = new Set(tools.map((tool) => tool.name));
  for (const required of routingSuiteRequiredTools) {
    if (!names.has(required)) throw new Error(`Live safe-authoring catalog is missing '${required}'.`);
  }
  for (const forbidden of [
    "revit_delete_element",
    "revit_unload_family",
    "revit_purge_unused",
    "revit_wipe_empty_tags",
    "revit_remove_filter_from_view",
    "revit_unload_link",
    "revit_remove_parameter_binding",
    "revit_delete_view_template",
    "revit_delete_saved_selection",
    "revit_workflow_view_cleanup",
    "revit_send_code_to_revit",
    "revit_list_baked_tools",
    "revit_run_baked_tool",
    "revit_list_bake_suggestions",
    "revit_accept_bake_suggestion",
    "revit_dismiss_bake_suggestion",
  ]) {
    if (names.has(forbidden)) throw new Error(`Live catalog cannot be labeled safe-authoring because it exposes '${forbidden}'.`);
  }
}

function validateLocalEndpoint(endpoint: string): void {
  let url: URL;
  try { url = new URL(endpoint); }
  catch { throw new Error("Catalog endpoint must be a valid localhost HTTP URL."); }
  if (url.protocol !== "http:" || (url.hostname !== "127.0.0.1" && url.hostname !== "localhost" && url.hostname !== "[::1]")) {
    throw new Error("Catalog endpoint must use localhost HTTP.");
  }
}

export async function fetchLiveCatalog(serverUrl: string, profile = "safe-authoring"): Promise<CatalogEnvelope> {
  requireRoutingProfile(profile);
  validateLocalEndpoint(serverUrl);
  const discovery = await callStateless(serverUrl, "server/discover", {});
  if (discovery.sessionId) throw new Error("server/discover returned Mcp-Session-Id; the catalog source is not stateless.");
  const discoverResult = discovery.rpc.result as {
    supportedVersions?: string[];
    instructions?: string;
    _meta?: Record<string, unknown>;
  } | undefined;
  if (!discoverResult?.supportedVersions?.includes("2026-07-28")) {
    throw new Error("server/discover does not advertise MCP 2026-07-28.");
  }

  const tools: ToolCatalogEntry[] = [];
  let cursor: string | undefined;

  do {
    const page = await callStateless(serverUrl, "tools/list", cursor ? { cursor } : {});
    if (page.sessionId) throw new Error("tools/list returned Mcp-Session-Id; the catalog source is not stateless.");
    const result = page.rpc.result as {
      tools?: Array<{ name: string; description?: string; inputSchema: Record<string, unknown>; annotations?: Record<string, unknown> }>;
      nextCursor?: string;
    } | undefined;
    if (!result || !Array.isArray(result.tools)) throw new Error("tools/list response did not contain a tools array.");
    for (const tool of result.tools) {
      if (!tool.name || !tool.description?.trim() || !tool.inputSchema) {
        throw new Error("tools/list returned a tool without a name, description, or input schema.");
      }
      tools.push({ name: tool.name, description: tool.description, inputSchema: tool.inputSchema, annotations: tool.annotations, toolset: "live" });
    }
    cursor = result.nextCursor;
  } while (cursor);

  const uniqueNames = new Set(tools.map((tool) => tool.name));
  if (uniqueNames.size !== tools.length) throw new Error("tools/list returned duplicate tool names.");
  tools.sort((left, right) => left.name.localeCompare(right.name));
  validateSafeCatalog(tools);
  const instructions = discoverResult.instructions ?? "";
  const serverInfo = discoverResult._meta?.["io.modelcontextprotocol/serverInfo"] as Record<string, unknown> | undefined;
  const envelope: CatalogEnvelope = {
    schemaVersion: 1,
    source: "live-tools-list",
    profile,
    capturedAt: new Date().toISOString(),
    protocolVersion: "2026-07-28",
    endpoint: serverUrl,
    serverInfo,
    serverInstructionsSha256: sha256(instructions),
    toolCount: tools.length,
    catalogSha256: catalogSha256(tools),
    tools,
  };
  validateCatalogEnvelope(envelope, profile, true);
  return envelope;
}

async function buildOfflineCatalogEnvelope(profile: string): Promise<CatalogEnvelope> {
  const tools = await buildCatalog(profile);
  const envelope: CatalogEnvelope = {
    schemaVersion: 1,
    source: "offline-reflection",
    profile,
    capturedAt: new Date().toISOString(),
    toolCount: tools.length,
    catalogSha256: catalogSha256(tools),
    tools,
  };
  validateCatalogEnvelope(envelope, profile, false);
  return envelope;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

export function validateCatalogEnvelope(
  envelope: CatalogEnvelope,
  expectedProfile = "safe-authoring",
  requireLive = false,
): void {
  if (!isRecord(envelope) || envelope.schemaVersion !== 1) {
    throw new Error("Catalog must be a schemaVersion 1 envelope.");
  }
  if (envelope.source !== "live-tools-list" && envelope.source !== "offline-reflection") {
    throw new Error("Catalog source must be live-tools-list or offline-reflection.");
  }
  if (requireLive && envelope.source !== "live-tools-list") {
    throw new Error("Scored runs require a catalog captured from live tools/list.");
  }
  if (envelope.profile !== expectedProfile) {
    throw new Error(`Catalog profile '${envelope.profile}' does not match '${expectedProfile}'.`);
  }
  if (!Number.isFinite(Date.parse(envelope.capturedAt))) {
    throw new Error("Catalog capturedAt must be a valid timestamp.");
  }
  if (!Array.isArray(envelope.tools)) throw new Error("Catalog envelope must contain a tools array.");
  for (const tool of envelope.tools) {
    if (!isRecord(tool) || typeof tool.name !== "string" || !tool.name ||
        typeof tool.description !== "string" || !tool.description.trim() ||
        !isRecord(tool.inputSchema)) {
      throw new Error("Catalog contains a tool without a name, description, or object input schema.");
    }
    if (tool.annotations !== undefined && !isRecord(tool.annotations)) {
      throw new Error(`Catalog tool '${tool.name}' has invalid annotations.`);
    }
  }
  const names = new Set(envelope.tools.map((tool) => tool.name));
  if (names.size !== envelope.tools.length) throw new Error("Catalog contains duplicate tool names.");
  if (envelope.toolCount !== envelope.tools.length) {
    throw new Error(`Catalog toolCount ${envelope.toolCount} does not match ${envelope.tools.length} tools.`);
  }
  const actualHash = catalogSha256(envelope.tools);
  if (!/^[a-f0-9]{64}$/.test(envelope.catalogSha256) || envelope.catalogSha256 !== actualHash) {
    throw new Error("Catalog SHA-256 does not match its tools.");
  }
  validateSafeCatalog(envelope.tools);

  if (envelope.source === "live-tools-list") {
    if (envelope.protocolVersion !== "2026-07-28") {
      throw new Error("Live catalog protocolVersion must be 2026-07-28.");
    }
    if (!isRecord(envelope.serverInfo) || envelope.serverInfo.name !== "cria-revit-mcp" ||
        typeof envelope.serverInfo.version !== "string" || !envelope.serverInfo.version) {
      throw new Error("Live catalog serverInfo must identify cria-revit-mcp.");
    }
    if (typeof envelope.endpoint !== "string") throw new Error("Live catalog must include its localhost endpoint.");
    validateLocalEndpoint(envelope.endpoint);
    if (!envelope.serverInstructionsSha256 || !/^[a-f0-9]{64}$/.test(envelope.serverInstructionsSha256)) {
      throw new Error("Live catalog must include a server instructions SHA-256.");
    }
  }
}

function catalogMetadata(envelope: CatalogEnvelope): Omit<CatalogEnvelope, "tools"> {
  const { tools: _tools, ...metadata } = envelope;
  return metadata;
}

function catalogEnvelopeSha256(envelope: CatalogEnvelope): string {
  return sha256(serializeJson(envelope));
}

function jsonish(value: unknown): unknown {
  if (typeof value !== "string") return value;
  const trimmed = value.trim();
  if ((trimmed.startsWith("[") && trimmed.endsWith("]")) ||
      (trimmed.startsWith("{") && trimmed.endsWith("}"))) {
    try { return JSON.parse(trimmed); } catch { return value; }
  }
  return value;
}

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .filter((key) => record[key] !== undefined)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stable(record[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value ?? null);
}

function semanticallyEqual(actual: unknown, expected: unknown): boolean {
  const left = jsonish(actual);
  const right = jsonish(expected);
  if (stable(left) === stable(right)) return true;
  if (typeof left === "string" && typeof right === "string") {
    return left.trim().toLowerCase() === right.trim().toLowerCase();
  }
  if (typeof left === "number" && typeof right === "number") {
    const leftNumber = Number(left);
    const rightNumber = Number(right);
    return Number.isFinite(leftNumber) && Number.isFinite(rightNumber) && leftNumber === rightNumber;
  }
  return false;
}

function isRepresentationOnly(actual: unknown, expected: unknown): boolean {
  if (semanticallyEqual(actual, expected)) return false;
  if ((typeof actual === "number" && typeof expected === "string") ||
      (typeof actual === "string" && typeof expected === "number")) {
    const leftNumber = Number(actual);
    const rightNumber = Number(expected);
    return Number.isFinite(leftNumber) && Number.isFinite(rightNumber) && leftNumber === rightNumber;
  }
  if (typeof actual === "string" && typeof expected === "string") {
    const normalize = (value: string) => value.trim().toLowerCase().replace(/[\s_-]+/g, "");
    return normalize(actual) === normalize(expected);
  }
  return false;
}

function validateRectangle(value: unknown, rule: Record<string, unknown>): boolean {
  const parsed = jsonish(value);
  if (!Array.isArray(parsed)) return false;
  const points = parsed.map((point) => {
    if (Array.isArray(point) && point.length >= 2) return { x: Number(point[0]), y: Number(point[1]) };
    if (point && typeof point === "object") {
      const record = point as Record<string, unknown>;
      return { x: Number(record.x), y: Number(record.y) };
    }
    return { x: Number.NaN, y: Number.NaN };
  });
  if (points.some((point) => !Number.isFinite(point.x) || !Number.isFinite(point.y))) return false;
  if (points.length === 5 && points[0].x === points[4].x && points[0].y === points[4].y) points.pop();
  if (points.length !== 4) return false;

  const xs = [...new Set(points.map((point) => point.x))].sort((a, b) => a - b);
  const ys = [...new Set(points.map((point) => point.y))].sort((a, b) => a - b);
  if (xs.length !== 2 || ys.length !== 2) return false;
  const actualDimensions = [xs[1] - xs[0], ys[1] - ys[0]].sort((a, b) => a - b);
  const expectedDimensions = [Number(rule.width), Number(rule.height)].sort((a, b) => a - b);
  const tolerance = Number(rule.tolerance ?? 0.001);
  const corners = new Set(points.map((point) => `${point.x},${point.y}`));
  const expectedCorners = new Set([`${xs[0]},${ys[0]}`, `${xs[0]},${ys[1]}`, `${xs[1]},${ys[0]}`, `${xs[1]},${ys[1]}`]);
  const edges = points.map((point, index) => {
    const next = points[(index + 1) % points.length];
    return { dx: next.x - point.x, dy: next.y - point.y };
  });
  const axisAligned = edges.every((edge) => (Math.abs(edge.dx) <= tolerance) !== (Math.abs(edge.dy) <= tolerance));
  const nonDegenerate = edges.every((edge) => Math.abs(edge.dx) > tolerance || Math.abs(edge.dy) > tolerance);
  return actualDimensions.every((dimension, index) => Math.abs(dimension - expectedDimensions[index]) <= tolerance) &&
    [...expectedCorners].every((corner) => corners.has(corner)) && axisAligned && nonDegenerate;
}

function scoreArguments(expected: ExpectedCall, actual: { arguments: Record<string, unknown> } | undefined): { score: number; notes: string[] } {
  if (!actual) return { score: 0, notes: ["Missing expected call arguments."] };
  const failures: string[] = [];
  let representationOnlyFailures = 0;

  for (const argument of expected.requiredArguments ?? []) {
    if (!(argument in actual.arguments)) failures.push(`Missing required argument '${argument}'.`);
  }

  for (const [argument, accepted] of Object.entries(expected.acceptedArguments ?? {})) {
    if (!(argument in actual.arguments)) continue;
    const value = actual.arguments[argument];
    if (!accepted.some((candidate) => semanticallyEqual(value, candidate))) {
      if (accepted.some((candidate) => isRepresentationOnly(value, candidate))) representationOnlyFailures += 1;
      else failures.push(`Argument '${argument}' did not match an accepted value.`);
    }
  }

  for (const [argument] of Object.entries(expected.derivedArguments ?? {})) {
    const value = actual.arguments[argument];
    if (typeof value !== "string" || !/(return|result|call\s*1|previous|element\s*id)/i.test(value)) {
      failures.push(`Argument '${argument}' did not reference the earlier call result.`);
    }
  }

  for (const [argument, rule] of Object.entries(expected.validationRules ?? {})) {
    if (rule.kind === "axis-aligned-rectangle" && !validateRectangle(actual.arguments[argument], rule)) {
      failures.push(`Argument '${argument}' did not form the required rectangle.`);
    }
  }

  if (failures.length === 0 && representationOnlyFailures === 0) return { score: 1, notes: [] };
  if (failures.length === 0 && representationOnlyFailures === 1) return { score: 0.5, notes: ["One representation-only argument mismatch."] };
  return { score: 0, notes: failures.length ? failures : ["Multiple argument representation mismatches."] };
}

function validateResponse(response: ModelResponse, cases: CasesFile): void {
  if (response.suite !== cases.suite) throw new Error(`Response suite must be '${cases.suite}'.`);
  if (!response.model?.provider || !response.model?.id || !response.model?.reasoning) {
    throw new Error("Response.model must contain provider, id, and reasoning.");
  }
  if (!Array.isArray(response.results)) throw new Error("Response.results must be an array.");
  const ids = response.results.map((result) => result.id);
  const expectedIds = new Set(cases.cases.map((benchmarkCase) => benchmarkCase.id));
  if (response.results.length !== cases.cases.length || ids.some((id) => !expectedIds.has(id))) {
    throw new Error("Response.results must contain exactly the benchmark case IDs and no extras.");
  }
  for (const result of response.results) {
    if (!Array.isArray(result.calls)) throw new Error(`Case '${result.id}' calls must be an array.`);
    for (const call of result.calls) {
      if (!call || typeof call.tool !== "string" || !call.tool) throw new Error(`Case '${result.id}' has an invalid tool name.`);
      if (!call.arguments || typeof call.arguments !== "object" || Array.isArray(call.arguments)) {
        throw new Error(`Case '${result.id}' tool arguments must be a JSON object.`);
      }
    }
  }
  for (const benchmarkCase of cases.cases) {
    if (ids.filter((id) => id === benchmarkCase.id).length !== 1) {
      throw new Error(`Response must contain case '${benchmarkCase.id}' exactly once.`);
    }
  }
}

export function scoreResponse(response: ModelResponse, cases: CasesFile, profile: string, toolCount: number): ScoreReport {
  validateResponse(response, cases);
  const resultById = new Map(response.results.map((result) => [result.id, result]));
  const caseScores: CaseScore[] = cases.cases.map((benchmarkCase) => {
    const actual = resultById.get(benchmarkCase.id)!;
    const expectedTools = benchmarkCase.expectedCalls.map((call) => call.tool);
    const actualTools = actual.calls.map((call) => call.tool);
    const denominator = Math.max(expectedTools.length, actualTools.length, 1);
    const matchingPositions = Array.from({ length: Math.min(expectedTools.length, actualTools.length) })
      .filter((_, index) => expectedTools[index] === actualTools[index]).length;
    const toolScore = expectedTools.length === 0 && actualTools.length === 0 ? 1 : matchingPositions / denominator;
    const argumentResults = benchmarkCase.expectedCalls.map((expected, index) =>
      expected.tool === actual.calls[index]?.tool
        ? scoreArguments(expected, actual.calls[index])
        : { score: 0, notes: [`Arguments were not scored because call ${index + 1} used the wrong tool.`] });
    const argumentScore = expectedTools.length === 0
      ? (actualTools.length === 0 ? 1 : 0)
      : argumentResults.reduce((sum, result) => sum + result.score, 0) / expectedTools.length;
    return {
      id: benchmarkCase.id,
      expectedTools,
      actualTools,
      toolScore,
      argumentScore,
      notes: argumentResults.flatMap((result) => result.notes),
    };
  });

  const average = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;
  const toolSelection = average(caseScores.map((score) => score.toolScore)) * 100;
  const argumentAccuracy = average(caseScores.map((score) => score.argumentScore)) * 100;
  return {
    suite: cases.suite,
    model: response.model,
    profile,
    toolCount,
    toolSelection,
    argumentAccuracy,
    overall: (toolSelection + argumentAccuracy) / 2,
    cases: caseScores,
  };
}

function fixed(value: number): string {
  return `${value.toFixed(1)}%`;
}

export function renderMarkdown(
  report: ScoreReport,
  provenance: {
    repository: RepositoryMetadata;
    catalog: Omit<CatalogEnvelope, "tools">;
    hashes: Omit<EvidenceHashes, "reportSha256">;
  },
): string {
  const rows = report.cases.map((item) =>
    `| ${item.id} | ${item.expectedTools.join(" -> ") || "No call"} | ${item.actualTools.join(" -> ") || "No call"} | ${item.toolScore.toFixed(2)} | ${item.argumentScore.toFixed(2)} | ${item.notes.join(" ") || ""} |`,
  );
  return `# Tool-routing benchmark run — ${new Date().toISOString().slice(0, 10)}\n\n` +
    `- Suite: ${report.suite}\n` +
    `- Commit: ${provenance.repository.commit}\n` +
    `- Dirty worktree: ${provenance.repository.dirty ? "Yes" : "No"}\n` +
    `- Version: ${provenance.repository.version}\n` +
    `- Provider: ${report.model.provider}\n` +
    `- Model: ${report.model.id}\n` +
    `- Reasoning: ${report.model.reasoning}\n` +
    `- Tool profile: ${report.profile}\n` +
    `- Tool count: ${report.toolCount}\n` +
    `- Catalog source: ${provenance.catalog.source}\n` +
    `- Catalog captured: ${provenance.catalog.capturedAt}\n` +
    `- Protocol: ${provenance.catalog.protocolVersion ?? "unknown"}\n` +
    `- Catalog SHA-256: ${provenance.hashes.catalogSha256}\n` +
    `- Catalog envelope SHA-256: ${provenance.hashes.catalogEnvelopeSha256}\n` +
    `- Cases SHA-256: ${provenance.hashes.casesSha256}\n` +
    `- Prompt SHA-256: ${provenance.hashes.promptSha256}\n` +
    `- Response SHA-256: ${provenance.hashes.responseSha256}\n\n` +
    `## Score\n\n` +
    `| Tool selection | Argument accuracy | Overall |\n|---:|---:|---:|\n` +
    `| ${fixed(report.toolSelection)} | ${fixed(report.argumentAccuracy)} | ${fixed(report.overall)} |\n\n` +
    `## Case results\n\n` +
    `| Case | Expected tools | Model tools | Tool score | Argument score | Notes |\n` +
    `|---|---|---|---:|---:|---|\n${rows.join("\n")}\n`;
}

function parseCli(argv: string[]): { command: string; options: Map<string, string | boolean> } {
  const command = argv[0] ?? "help";
  const options = new Map<string, string | boolean>();
  for (let index = 1; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) throw new Error(`Unexpected argument '${token}'.`);
    const next = argv[index + 1];
    if (next && !next.startsWith("--")) {
      options.set(token.slice(2), next);
      index += 1;
    } else options.set(token.slice(2), true);
  }
  return { command, options };
}

function option(options: Map<string, string | boolean>, name: string, fallback?: string): string {
  const value = options.get(name);
  if (typeof value === "string") return value;
  if (fallback !== undefined) return fallback;
  throw new Error(`Missing required --${name}.`);
}

async function loadCases(): Promise<CasesFile> {
  return JSON.parse(await readFile(casesPath, "utf8")) as CasesFile;
}

async function loadModels(): Promise<ModelRegistry> {
  return JSON.parse(await readFile(modelsPath, "utf8")) as ModelRegistry;
}

async function registeredModel(modelId: string): Promise<RegisteredModel> {
  const registry = await loadModels();
  const model = registry.models.find((entry) => entry.id === modelId);
  if (!model) throw new Error(`Model '${modelId}' is not registered in models.json.`);
  return model;
}

export function validateModelMetadata(model: ModelResponse["model"], registered: RegisteredModel): void {
  if (!model || model.id !== registered.id || model.provider !== registered.provider || model.reasoning !== registered.reasoning) {
    throw new Error("Response model provider, id, and reasoning must exactly match models.json.");
  }
}

function outputContract(cases: CasesFile, model: RegisteredModel): Record<string, unknown> {
  return {
    fixedValues: {
      suite: cases.suite,
      model: { provider: model.provider, id: model.id, reasoning: model.reasoning },
    },
    results: {
      requiredCaseIds: cases.cases.map((benchmarkCase) => benchmarkCase.id),
      exactlyOneResultPerCase: true,
      item: {
        id: "one required case ID",
        calls: {
          type: "array",
          description: "Zero or more ordered tool calls. Use [] when no supplied tool should be called.",
          item: { tool: "a tool name from tools", arguments: "a JSON object matching that tool inputSchema" },
        },
      },
    },
  };
}

export async function buildPromptPayload(
  modelId: string,
  profile: string,
  catalog: CatalogEnvelope,
): Promise<Record<string, unknown>> {
  requireRoutingProfile(profile);
  validateCatalogEnvelope(catalog, profile, false);
  const [cases, model] = await Promise.all([loadCases(), registeredModel(modelId)]);
  return {
    schemaVersion: 1,
    suite: cases.suite,
    model,
    profile,
    catalogProvenance: {
      ...catalogMetadata(catalog),
      catalogEnvelopeSha256: catalogEnvelopeSha256(catalog),
    },
    instruction: "Plan the smallest correct ordered tool call chain for every synthetic request. Do not execute tools or connect to Revit. Use only the supplied tools. Preserve millimeter units and schema types. Return a valid JSON response matching outputContract; outputContract describes the structure and is not a response to copy. Each case calls zero or more tools. When a value depends on an earlier call, use a clear placeholder that names that call result.",
    tools: catalog.tools.map(({ name, description, inputSchema, annotations }) => ({
      name,
      description,
      inputSchema,
      ...(annotations ? { annotations } : {}),
    })),
    cases: cases.cases.map(({ id, request }) => ({ id, request })),
    outputContract: outputContract(cases, model),
  };
}

async function repositoryMetadata(): Promise<RepositoryMetadata> {
  const commitResult = Bun.spawnSync(["git", "rev-parse", "HEAD"], { cwd: repoRoot });
  if (commitResult.exitCode !== 0) throw new Error("Could not read git commit.");
  const statusResult = Bun.spawnSync(["git", "status", "--porcelain", "--untracked-files=normal"], { cwd: repoRoot });
  if (statusResult.exitCode !== 0) throw new Error("Could not read git worktree status.");
  const project = await readFile(path.join(repoRoot, "src", "server", "RvtMcp.Server.csproj"), "utf8");
  return {
    commit: commitResult.stdout.toString().trim(),
    dirty: Boolean(statusResult.stdout.toString().trim()),
    version: /<Version>([^<]+)<\/Version>/.exec(project)?.[1] ?? "unknown",
  };
}

async function runAdapter(modelId: string, promptText: string, configPath: string): Promise<{ response: ModelResponse; raw: string }> {
  const config = JSON.parse(await readFile(configPath, "utf8")) as {
    adapters: Record<string, { command: string[]; timeoutMs?: number; requiredEnvironment?: string[] }>;
  };
  const adapter = config.adapters[modelId];
  if (!adapter || !Array.isArray(adapter.command) || adapter.command.length === 0) {
    throw new Error(`No command adapter configured for '${modelId}'.`);
  }
  for (const name of adapter.requiredEnvironment ?? []) {
    if (!process.env[name]) throw new Error(`Required environment variable '${name}' is not set.`);
  }
  const command = adapter.command.map((token) => token.replaceAll("{model}", modelId));
  const inheritedEnvironment = ["PATH", "Path", "SystemRoot", "WINDIR", "TEMP", "TMP", "PATHEXT", "ComSpec"];
  const adapterEnvironment: Record<string, string> = {};
  for (const name of [...inheritedEnvironment, ...(adapter.requiredEnvironment ?? [])]) {
    const value = process.env[name];
    if (value !== undefined) adapterEnvironment[name] = value;
  }
  const processHandle = Bun.spawn(command, { cwd: repoRoot, stdin: "pipe", stdout: "pipe", stderr: "pipe", env: adapterEnvironment });
  processHandle.stdin.write(promptText);
  processHandle.stdin.end();
  const timeout = setTimeout(() => processHandle.kill(), adapter.timeoutMs ?? 180_000);
  const [exitCode, stdout, stderr] = await Promise.all([
    processHandle.exited,
    new Response(processHandle.stdout).text(),
    new Response(processHandle.stderr).text(),
  ]);
  clearTimeout(timeout);
  if (exitCode !== 0) throw new Error(`Adapter failed with exit code ${exitCode}: ${stderr.trim()}`);
  try { return { response: JSON.parse(stdout) as ModelResponse, raw: stdout }; }
  catch { throw new Error("Adapter output was not strict JSON."); }
}

function safeFileSegment(value: string): string {
  const normalized = value.replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^\.+|\.+$/g, "");
  return normalized || "model";
}

export async function writeEvidenceBundle(input: {
  mode: "score" | "run";
  catalog: CatalogEnvelope;
  casesText: string;
  promptText: string;
  responseText: string;
  report: ScoreReport;
  repository: RepositoryMetadata;
  evidenceRoot?: string;
  createdAt?: string;
}): Promise<{ directory: string; reportPath: string; manifestPath: string; reportText: string }> {
  const createdAt = input.createdAt ?? new Date().toISOString();
  const hashesWithoutReport: Omit<EvidenceHashes, "reportSha256"> = {
    casesSha256: sha256(input.casesText),
    catalogSha256: input.catalog.catalogSha256,
    catalogEnvelopeSha256: catalogEnvelopeSha256(input.catalog),
    promptSha256: sha256(input.promptText),
    responseSha256: sha256(input.responseText),
  };
  const reportText = renderMarkdown(input.report, {
    repository: input.repository,
    catalog: catalogMetadata(input.catalog),
    hashes: hashesWithoutReport,
  });
  const hashes: EvidenceHashes = { ...hashesWithoutReport, reportSha256: sha256(reportText) };
  const runId = `${createdAt.replace(/[:.]/g, "-")}-${safeFileSegment(input.report.model.id)}-${hashes.responseSha256.slice(0, 8)}`;
  const directory = path.join(input.evidenceRoot ?? path.join(localOutputDir, "runs"), runId);
  const reportPath = path.join(directory, "report.md");
  const manifestPath = path.join(directory, "manifest.json");
  const manifest: EvidenceManifest = {
    schemaVersion: 1,
    suite: input.report.suite,
    createdAt,
    mode: input.mode,
    repository: input.repository,
    model: input.report.model,
    profile: input.report.profile,
    catalog: catalogMetadata(input.catalog),
    hashes,
    scores: {
      toolSelection: input.report.toolSelection,
      argumentAccuracy: input.report.argumentAccuracy,
      overall: input.report.overall,
    },
    files: {
      catalog: "catalog.json",
      cases: "cases.json",
      prompt: "prompt.json",
      response: "response.json",
      report: "report.md",
      manifest: "manifest.json",
    },
  };

  await mkdir(directory, { recursive: true });
  await Promise.all([
    writeFile(path.join(directory, "catalog.json"), serializeJson(input.catalog)),
    writeFile(path.join(directory, "cases.json"), input.casesText),
    writeFile(path.join(directory, "prompt.json"), input.promptText),
    writeFile(path.join(directory, "response.json"), input.responseText),
    writeFile(reportPath, reportText),
  ]);
  await writeFile(manifestPath, serializeJson(manifest));
  return { directory, reportPath, manifestPath, reportText };
}

function parseJsonText<T>(text: string, label: string): T {
  try { return JSON.parse(text) as T; }
  catch { throw new Error(`${label} is not strict JSON.`); }
}

async function readCatalogEnvelopeFile(
  catalogPath: string,
  profile: string,
  requireLive: boolean,
): Promise<CatalogEnvelope> {
  const envelope = parseJsonText<CatalogEnvelope>(await readFile(path.resolve(catalogPath), "utf8"), "Catalog file");
  validateCatalogEnvelope(envelope, profile, requireLive);
  return envelope;
}

function validatePromptPayload(actual: Record<string, unknown>, expected: Record<string, unknown>): void {
  if (stable(actual) !== stable(expected)) {
    throw new Error("Prompt file does not match the selected catalog, cases, model registry, and output contract.");
  }
}

async function main(): Promise<void> {
  const { command, options } = parseCli(Bun.argv.slice(2));
  const profile = option(options, "profile", "safe-authoring");
  requireRoutingProfile(profile);

  const resolveDevelopmentCatalog = async (): Promise<CatalogEnvelope> => {
    const url = options.get("url");
    const catalogPath = options.get("catalog");
    if (typeof url === "string" && typeof catalogPath === "string") {
      throw new Error("Use only one catalog source: --url or --catalog.");
    }
    if (typeof url === "string") return fetchLiveCatalog(url, profile);
    if (typeof catalogPath === "string") return readCatalogEnvelopeFile(catalogPath, profile, false);
    return buildOfflineCatalogEnvelope(profile);
  };

  if (command === "catalog") {
    const catalog = await resolveDevelopmentCatalog();
    const destination = options.get("out");
    const body = serializeJson(catalog);
    if (typeof destination === "string") {
      await mkdir(path.dirname(path.resolve(destination)), { recursive: true });
      await writeFile(path.resolve(destination), body);
    } else process.stdout.write(body);
    return;
  }

  if (command === "prompt") {
    const modelId = option(options, "model");
    const payload = await buildPromptPayload(modelId, profile, await resolveDevelopmentCatalog());
    const destination = option(options, "out", path.join(localOutputDir, `prompt-${safeFileSegment(modelId)}.json`));
    await mkdir(path.dirname(path.resolve(destination)), { recursive: true });
    await writeFile(path.resolve(destination), serializeJson(payload));
    console.log(destination);
    return;
  }

  if (command === "score" || command === "run") {
    const modelId = option(options, "model");
    if (options.has("url")) {
      throw new Error("Scored runs require a previously captured --catalog file; --url is not accepted.");
    }
    const catalog = await readCatalogEnvelopeFile(option(options, "catalog"), profile, true);
    const expectedPrompt = await buildPromptPayload(modelId, profile, catalog);
    let promptText: string;
    let responseText: string;
    let response: ModelResponse;

    if (command === "run") {
      promptText = serializeJson(expectedPrompt);
      const adapterResult = await runAdapter(
        modelId,
        promptText,
        path.resolve(option(options, "adapters", path.join(benchmarksDir, "adapters.local.json"))),
      );
      response = adapterResult.response;
      responseText = adapterResult.raw;
    } else {
      promptText = await readFile(path.resolve(option(options, "prompt")), "utf8");
      validatePromptPayload(parseJsonText<Record<string, unknown>>(promptText, "Prompt file"), expectedPrompt);
      responseText = await readFile(path.resolve(option(options, "response")), "utf8");
      response = parseJsonText<ModelResponse>(responseText, "Response file");
    }

    const [casesText, metadata, model] = await Promise.all([
      readFile(casesPath, "utf8"),
      repositoryMetadata(),
      registeredModel(modelId),
    ]);
    validateModelMetadata(response.model, model);
    const cases = parseJsonText<CasesFile>(casesText, "Cases file");
    const report = scoreResponse(response, cases, profile, catalog.toolCount);
    const evidence = await writeEvidenceBundle({
      mode: command,
      catalog,
      casesText,
      promptText,
      responseText,
      report,
      repository: metadata,
    });

    const requestedReport = options.get("report");
    let reportPath = evidence.reportPath;
    if (typeof requestedReport === "string") {
      reportPath = path.resolve(requestedReport);
      await mkdir(path.dirname(reportPath), { recursive: true });
      await writeFile(reportPath, evidence.reportText);
    }
    console.log(JSON.stringify({
      evidence: evidence.directory,
      manifest: evidence.manifestPath,
      report: reportPath,
      toolSelection: report.toolSelection,
      argumentAccuracy: report.argumentAccuracy,
      overall: report.overall,
    }));
    return;
  }

  console.log("Commands:\n  catalog [--url http://127.0.0.1:8200/] [--out file]\n  prompt --model <id> [--url URL | --catalog file] [--out file]\n  score --model <id> --catalog <live-catalog> --prompt <file> --response <file> [--report file]\n  run --model <id> --catalog <live-catalog> [--adapters adapters.local.json] [--report file]\n\nThe cria-tool-routing-v1 suite uses the safe-authoring profile only. Offline catalogs are development-only and cannot be scored.");
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
