// Import Grok CLI chat_history.jsonl into bridge SSE event history so the phone
// shows the full conversation when resuming a CLI session (not an empty chat).

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const SESSIONS_ROOT = join(homedir(), ".grok", "sessions");

/** Extract plain text from a chat_history content field (string | blocks[]). */
function contentText(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (typeof b === "string") return b;
        if (b && typeof b === "object") {
          if (typeof b.text === "string") return b.text;
          if (b.type === "summary_text" && typeof b.text === "string") return b.text;
        }
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  return "";
}

/** Strip outer <user_query> wrappers the CLI sometimes embeds. */
function cleanUserText(text) {
  let t = String(text || "").trim();
  const m = t.match(/<user_query>\s*([\s\S]*?)\s*<\/user_query>/i);
  if (m) t = m[1].trim();
  return t;
}

/**
 * Locate ~/.grok/sessions/<cwd-enc>/<sessionId>/chat_history.jsonl
 * @returns {string|null} path to chat_history.jsonl
 */
export function findCliHistoryPath(grokSessionId) {
  if (!grokSessionId || !existsSync(SESSIONS_ROOT)) return null;
  let cwdDirs;
  try {
    cwdDirs = readdirSync(SESSIONS_ROOT, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const ent of cwdDirs) {
    if (!ent.isDirectory()) continue;
    const hist = join(SESSIONS_ROOT, ent.name, grokSessionId, "chat_history.jsonl");
    if (existsSync(hist)) return hist;
  }
  return null;
}

/**
 * Parse CLI history into bridge event objects (no ids).
 * Skips system + synthetic user lines; maps user/assistant/reasoning.
 * Caps at maxEvents to keep phone SSE replay snappy.
 */
export function parseCliHistory(historyPath, { maxEvents = 800 } = {}) {
  if (!historyPath || !existsSync(historyPath)) return [];
  let raw;
  try {
    raw = readFileSync(historyPath, "utf8");
  } catch {
    return [];
  }

  const out = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    const type = o.type || o.role;
    if (type === "system") continue;
    if (type === "user") {
      // Compaction / project_instructions / system_reminder noise
      if (o.synthetic_reason) continue;
      const text = cleanUserText(contentText(o.content));
      if (!text) continue;
      out.push({ kind: "turn_start", text, at: o.ts || o.created_at || undefined });
      continue;
    }
    if (type === "assistant") {
      const text = contentText(o.content).trim();
      if (!text) continue;
      out.push({ kind: "text", text });
      continue;
    }
    if (type === "reasoning" || type === "thought") {
      const text = contentText(o.summary || o.content).trim();
      if (!text) continue;
      // Keep thoughts short on resume — full encrypted blobs are useless on phone
      const clipped = text.length > 1200 ? text.slice(0, 1200) + "…" : text;
      out.push({ kind: "thought", text: clipped });
      continue;
    }
    // tool_result / tool_call — optional compact line
    if (type === "tool_result" || type === "tool_call" || type === "function_call" || type === "tool_use") {
      const name =
        o.name || o.tool || o.tool_name || o.function?.name ||
        o.toolCall?.name || o.tool_call?.name || "tool";
      const status = o.status || (o.is_error ? "failed" : "done");
      const tid = o.id || o.tool_use_id || o.tool_call_id || undefined;
      out.push({
        kind: "tool_call",
        tool: name,
        title: name,
        id: tid,
      });
      const outText =
        typeof o.content === "string" ? o.content
        : typeof o.output === "string" ? o.output
        : typeof o.result === "string" ? o.result
        : "";
      out.push({
        kind: "tool_update",
        id: tid,
        status,
        output: outText ? outText.slice(0, 400) : undefined,
      });
    }
  }

  // Keep the tail if huge (most recent context matters for the phone UI)
  if (out.length > maxEvents) return out.slice(out.length - maxEvents);
  return out;
}

/**
 * Seed a bridge Session with CLI history events (no live subscribers yet).
 * @param {import('./sessions.mjs').Session} session — must expose seedHistory or we mutate _events
 */
export function seedSessionFromCli(session, grokSessionId, opts = {}) {
  const path = findCliHistoryPath(grokSessionId);
  if (!path) return { ok: false, reason: "history_not_found", count: 0 };
  const events = parseCliHistory(path, opts);
  if (!events.length) return { ok: true, reason: "empty", count: 0, path };

  if (typeof session.seedHistory === "function") {
    session.seedHistory(events);
  } else {
    // Fallback: push via emit (works if no subscribers)
    for (const ev of events) session.emit(ev);
  }
  if (typeof session.saveHistory === "function") session.saveHistory();
  return { ok: true, count: events.length, path };
}
