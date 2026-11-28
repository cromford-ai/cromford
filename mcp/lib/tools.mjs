// The tool registry. Each mcp/tools/*.mjs exports `tools`; adding a tool is
// adding a file, never editing a shared list.
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { consoleFetch, redact } from './console.mjs';

const KINDS = new Set(['read', 'write', 'guarded']);
const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const text = (t) => ({ content: [{ type: 'text', text: t }] });
const fail = (t) => ({ ...text(t), isError: true });

const valid = (t) =>
  isPlain(t) && typeof t.name === 'string' && t.name !== '' && typeof t.handler === 'function' &&
  isPlain(t.inputSchema) && t.inputSchema.type === 'object' && KINDS.has(t.kind) &&
  (t.precheck === undefined || typeof t.precheck === 'function');

export async function loadTools(dir) {
  const path = dir instanceof URL ? fileURLToPath(dir) : dir;
  const registry = new Map();
  const from = new Map();
  for (const file of readdirSync(path).filter((f) => f.endsWith('.mjs')).sort()) {
    const mod = await import(pathToFileURL(join(path, file)).href);
    if (!Array.isArray(mod.tools)) throw new Error(`no tools export in ${file}`);
    for (const t of mod.tools) {
      if (!valid(t)) throw new Error(`invalid tool ${t?.name} in ${file}`);
      if (registry.has(t.name)) throw new Error(`duplicate tool name: ${t.name} (${from.get(t.name)}, ${file})`);
      registry.set(t.name, t);
      from.set(t.name, file);
    }
  }
  return registry;
}

// The first key path the schema closes over and does not declare, or null.
function unknownKey(args, schema, prefix = '') {
  const props = schema.properties ?? {};
  for (const [k, v] of Object.entries(args)) {
    const p = prefix + k;
    if (!Object.hasOwn(props, k)) {
      if (schema.additionalProperties === false) return p;
      continue;
    }
    if (isPlain(v) && isPlain(props[k]) && props[k].type === 'object') {
      const nested = unknownKey(v, props[k], p + '.');
      if (nested) return nested;
    }
  }
  return null;
}

export async function callTool(registry, name, args, ctx) {
  const tool = registry.get(name);
  if (!tool) return null;
  args = args ?? {};
  if (!isPlain(args)) return fail('invalid_arguments');
  try {
    const code = await tool.precheck?.(args, ctx);
    if (code) return fail(String(code));
    const bad = unknownKey(args, tool.inputSchema);
    if (bad) return fail(`invalid_arguments: ${bad}`);
    return await tool.handler(args, ctx);
  } catch (err) {
    ctx.log?.(`tool ${name} failed: ${redact(err?.message ?? err, ctx.cfg)}`);
    return fail('tool_failed');
  }
}

export async function forward(ctx, method, path, body) {
  const r = await (ctx.consoleFetch ?? consoleFetch)(ctx.cfg, method, path, body);
  if (r.ok) {
    const out = text(JSON.stringify(r.data));
    if (isPlain(r.data)) out.structuredContent = r.data;
    return out;
  }
  if (r.status === 404) return fail(`console route not available: ${path}`);
  return fail(r.error);
}
