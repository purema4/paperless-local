#!/usr/bin/env node
// Claude Desktop extension for Paperless.
//
// It runs on the employee's computer (which is in the tailnet) and:
//   - forwards every tool of the remote paperless-mcp server (search, read, edit...)
//   - adds `upload_local_files`: reads files from this computer and sends them
//     straight to the Paperless REST API (multipart), so an agent never has to
//     pass megabytes of base64 through a tool call.
//
// Config comes from the extension settings (manifest.json -> env):
//   PAPERLESS_MCP_URL    https://<server>.ts.net:10000/mcp
//   PAPERLESS_URL        https://<server>.ts.net (optional, derived from the MCP URL)
//   PAPERLESS_TOKEN      the employee's Paperless API token
//   argv                 folders the upload tool may read from (optional)
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";

const MCP_URL = process.env.PAPERLESS_MCP_URL || "";
const TOKEN = (process.env.PAPERLESS_TOKEN || "").trim();
const PAPERLESS_URL = (process.env.PAPERLESS_URL || "").trim().replace(/\/+$/, "") ||
  (MCP_URL ? `${new URL(MCP_URL).protocol}//${new URL(MCP_URL).hostname}` : "");
const MAX_BYTES = 100 * 1024 * 1024;
const log = (...a) => console.error("[paperless]", ...a); // stdout is the MCP channel

// ------------------------------------------------------------ allowed folders
const home = os.homedir();
const defaultDirs = ["Downloads", "Documents", "Desktop", "Pictures", "Claude",
  "OneDrive/Documents", "OneDrive/Desktop", "OneDrive/Pictures"].map((d) => path.join(home, d));
const argDirs = process.argv.slice(2).filter((d) => d && !d.includes("${"));
const candidateDirs = argDirs.length ? argDirs : defaultDirs;
const ALLOWED = [];
for (const d of candidateDirs) {
  try { ALLOWED.push(await fs.realpath(d)); } catch { /* folder doesn't exist */ }
}

const inside = (p, dir) => {
  const rel = path.relative(dir, p);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
};
const isFile = async (p) => { try { return (await fs.stat(p)).isFile(); } catch { return false; } };

// The agent may give a path from its own sandbox (e.g. /sessions/x/mnt/Documents/recus/a.pdf)
// that maps to C:\Users\me\Documents\recus\a.pdf here: match the path's trailing
// segments against each allowed folder.
async function resolveLocal(given) {
  if (path.isAbsolute(given) && await isFile(given)) {
    const real = await fs.realpath(given);
    if (ALLOWED.some((d) => inside(real, d))) return real;
    throw new Error(`hors des dossiers autorisés: ${given}`);
  }
  const segs = given.split(/[\\/]+/).filter(Boolean);
  for (const dir of ALLOWED) {
    const base = path.basename(dir).toLowerCase();
    const at = segs.map((s) => s.toLowerCase()).lastIndexOf(base);
    const tries = [];
    if (at >= 0) tries.push(segs.slice(at + 1));
    for (let k = segs.length; k >= 1; k--) tries.push(segs.slice(segs.length - k));
    for (const t of tries) {
      if (!t.length) continue;
      const p = path.join(dir, ...t);
      if (await isFile(p)) {
        const real = await fs.realpath(p);
        if (inside(real, dir)) return real;
      }
    }
  }
  throw new Error(`introuvable sur cet ordinateur: ${given}`);
}

// ------------------------------------------------------------ Paperless REST
async function paperless(pathname, init = {}) {
  const res = await fetch(`${PAPERLESS_URL}${pathname}`, {
    ...init,
    headers: { Authorization: `Token ${TOKEN}`, Accept: "application/json", ...(init.headers || {}) },
    signal: AbortSignal.timeout(120_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Paperless ${res.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}

async function uploadOne(given, title) {
  const file = await resolveLocal(given);
  const { size } = await fs.stat(file);
  if (size > MAX_BYTES) throw new Error(`trop gros (${(size / 1e6).toFixed(0)} Mo)`);
  const form = new FormData();
  form.append("document", new Blob([await fs.readFile(file)]), path.basename(file));
  if (title) form.append("title", title);
  const task = await paperless("/api/documents/post_document/", { method: "POST", body: form });
  return { file, task: typeof task === "string" ? task : task?.task_id ?? String(task) };
}

// Wait (bounded) for Paperless to finish consuming, to report document ids and duplicates.
async function waitTasks(items, budgetMs = 90_000) {
  const end = Date.now() + budgetMs;
  const pending = new Set(items.filter((i) => i.task).map((i) => i.task));
  while (pending.size && Date.now() < end) {
    for (const id of [...pending]) {
      try {
        const r = await paperless(`/api/tasks/?task_id=${encodeURIComponent(id)}`);
        const t = Array.isArray(r) ? r[0] : r?.results?.[0];
        // Paperless 2.x: "SUCCESS" + related_document + result;
        // 3.x: "success" + related_document_ids + result_data.error_message
        const status = String(t?.status || "").toUpperCase();
        if (["SUCCESS", "FAILURE", "REVOKED"].includes(status)) {
          const it = items.find((i) => i.task === id);
          it.status = status;
          const docId = t.related_document ?? t.related_document_ids?.[0];
          it.document_id = docId ? Number(docId) : undefined;
          if (status !== "SUCCESS") it.message = t.result_data?.error_message ?? t.result;
          pending.delete(id);
        }
      } catch { /* retry next round */ }
    }
    if (pending.size) await new Promise((r) => setTimeout(r, 3000));
  }
  for (const it of items) if (it.task && !it.status) it.status = "EN COURS (Paperless traite encore)";
}

const UPLOAD_TOOL = {
  name: "upload_local_files",
  description:
    "Ajoute dans Paperless des fichiers (PDF, photos de reçus...) qui sont sur l'ordinateur de l'utilisateur. " +
    "Utilise cet outil plutôt que post_document : pas de base64, pas de limite de taille pratique, plusieurs fichiers d'un coup. " +
    "Enregistre d'abord les fichiers dans un de ces dossiers (dans Cowork : le dossier partagé), puis donne leurs chemins " +
    "(chemin complet de cet ordinateur, ou chemin de ton espace de travail : il est retrouvé à partir des derniers dossiers et du nom du fichier). " +
    `Dossiers autorisés : ${ALLOWED.join(" ; ") || "(aucun trouvé)"}. ` +
    "Paperless classe ensuite les reçus automatiquement (montants, TPS/TVQ) en quelques minutes.",
  inputSchema: {
    type: "object",
    properties: {
      files: {
        type: "array",
        minItems: 1,
        maxItems: 200,
        items: {
          type: "object",
          properties: {
            path: { type: "string", description: "Chemin du fichier" },
            title: { type: "string", description: "Titre (optionnel, sinon l'IA en met un)" },
          },
          required: ["path"],
        },
      },
    },
    required: ["files"],
  },
};

async function handleUpload(args) {
  const files = Array.isArray(args?.files) ? args.files : [];
  const items = [];
  for (const f of files) {
    try {
      items.push({ given: f.path, ...(await uploadOne(String(f.path || ""), f.title)) });
    } catch (e) {
      items.push({ given: f.path, status: "ERREUR", message: e.message });
    }
  }
  await waitTasks(items);
  const ok = items.filter((i) => i.status === "SUCCESS").length;
  const lines = items.map((i) =>
    `- ${i.given}: ${i.status}${i.document_id ? ` (document ${i.document_id})` : ""}${i.message ? ` - ${i.message}` : ""}`);
  return {
    content: [{ type: "text", text: `${ok}/${items.length} ajoutés.\n${lines.join("\n")}` }],
    isError: ok === 0 && items.length > 0,
  };
}

// ------------------------------------------------------------ remote MCP
let remote = null;
async function getRemote() {
  if (remote) return remote;
  const client = new Client({ name: "paperless-desktop", version: "1.1.0" });
  await client.connect(new StreamableHTTPClientTransport(new URL(MCP_URL), {
    requestInit: { headers: { Authorization: `Bearer ${TOKEN}` } },
  }));
  remote = client;
  return client;
}
const unreachable = (e) =>
  `Serveur Paperless injoignable (${e.message}). Vérifie que Tailscale est connecté sur cet ordinateur.`;

// ------------------------------------------------------------ local server
const server = new Server({ name: "paperless", version: "1.1.0" }, { capabilities: { tools: {} } });

server.setRequestHandler(ListToolsRequestSchema, async () => {
  let tools = [];
  try {
    tools = (await (await getRemote()).listTools()).tools;
  } catch (e) {
    remote = null;
    log(unreachable(e));
  }
  return { tools: [UPLOAD_TOOL, ...tools.filter((t) => t.name !== UPLOAD_TOOL.name)] };
});

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args } = req.params;
  if (name === UPLOAD_TOOL.name) {
    try { return await handleUpload(args); }
    catch (e) { return { content: [{ type: "text", text: unreachable(e) }], isError: true }; }
  }
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      return await (await getRemote()).callTool({ name, arguments: args });
    } catch (e) {
      remote = null; // stale session: reconnect once
      if (attempt === 1) return { content: [{ type: "text", text: unreachable(e) }], isError: true };
    }
  }
});

if (!MCP_URL || !TOKEN) log("PAPERLESS_MCP_URL or PAPERLESS_TOKEN missing");
log(`allowed folders: ${ALLOWED.join(", ") || "none"}`);
await server.connect(new StdioServerTransport());
