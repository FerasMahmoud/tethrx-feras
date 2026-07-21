// Read-only listing of Grok CLI sessions under ~/.grok/sessions/ so the phone
// app can resume a prior conversation via resumeGrokSessionId.
//
// Layout:
//   ~/.grok/sessions/<url-encoded-cwd>/<session-uuid>/summary.json
// Plus optional active markers from ~/.grok/active_sessions.json.

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const SESSIONS_ROOT = join(homedir(), ".grok", "sessions");
const ACTIVE_PATH = join(homedir(), ".grok", "active_sessions.json");

function loadActiveIds() {
  try {
    if (!existsSync(ACTIVE_PATH)) return new Set();
    const raw = JSON.parse(readFileSync(ACTIVE_PATH, "utf8"));
    if (!Array.isArray(raw)) return new Set();
    return new Set(raw.map((r) => r?.session_id).filter(Boolean));
  } catch {
    return new Set();
  }
}

function readSummary(summaryPath) {
  try {
    const s = JSON.parse(readFileSync(summaryPath, "utf8"));
    const info = s.info || {};
    const id = info.id || null;
    if (!id) return null;
    // Grok marks spawned workers with session_kind: "subagent" + agent_name
    // (general-purpose, explore, …). Main interactive sessions use grok-build-plan.
    const sessionKind = s.session_kind || info.session_kind || "main";
    const agentName = s.agent_name || info.agent_name || "";
    return {
      id,
      cwd: info.cwd || "",
      title: s.generated_title || s.title || "",
      summary: s.session_summary || s.summary || "",
      model: s.current_model_id || "",
      effort: s.reasoning_effort || "",
      createdAt: s.created_at || "",
      updatedAt: s.updated_at || "",
      lastActiveAt: s.last_active_at || s.updated_at || s.created_at || "",
      messageCount: s.num_chat_messages ?? s.num_messages ?? 0,
      sessionKind,
      agentName,
      isSubagent: sessionKind === "subagent",
    };
  } catch {
    return null;
  }
}

/**
 * List Grok CLI sessions for resume in the phone app.
 * @param {{ limit?: number, cwdFilter?: string|null }} opts
 * @returns {Array<{id,cwd,title,summary,model,effort,createdAt,updatedAt,lastActiveAt,messageCount,active}>}
 */
export function listGrokSessions({ limit = 50, cwdFilter = null } = {}) {
  const out = [];
  if (!existsSync(SESSIONS_ROOT)) return out;

  const active = loadActiveIds();
  const cap = Math.max(1, Math.min(Number(limit) || 50, 500));
  const filter = cwdFilter ? String(cwdFilter) : null;

  let cwdDirs;
  try {
    cwdDirs = readdirSync(SESSIONS_ROOT, { withFileTypes: true });
  } catch {
    return out;
  }

  for (const cwdEnt of cwdDirs) {
    if (!cwdEnt.isDirectory()) continue;
    // Skip non-session artifacts (e.g. session_search.sqlite lives at root)
    const cwdPath = join(SESSIONS_ROOT, cwdEnt.name);
    let sessionDirs;
    try {
      sessionDirs = readdirSync(cwdPath, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const sessEnt of sessionDirs) {
      if (!sessEnt.isDirectory()) continue;
      const summaryPath = join(cwdPath, sessEnt.name, "summary.json");
      if (!existsSync(summaryPath)) continue;
      const row = readSummary(summaryPath);
      if (!row) continue;
      if (filter && row.cwd !== filter) continue;
      row.active = active.has(row.id);
      out.push(row);
    }
  }

  out.sort((a, b) => String(b.lastActiveAt).localeCompare(String(a.lastActiveAt)));
  return out.slice(0, cap);
}
