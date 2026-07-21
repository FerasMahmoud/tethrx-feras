// Read-only filesystem helpers for phone path autocomplete.
// No writes. readdir/stat only; failures become empty results or thrown errors
// the route layer turns into 4xx.

import { readdirSync, statSync, lstatSync, existsSync, readFileSync } from "node:fs";
import { join, resolve, dirname, basename, extname, sep } from "node:path";
import { homedir } from "node:os";

const IMAGE_EXT = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp"]);
const MAX_FILE_BYTES = 8 * 1024 * 1024;

function expandHome(p) {
  if (p == null || p === "") return p;
  const s = String(p);
  if (s === "~") return homedir();
  if (s.startsWith("~/") || s.startsWith("~\\")) return join(homedir(), s.slice(2));
  return s;
}

/** Paths the phone may list/read — home, tmp, and common WSL mounts only. */
const ALLOWED_ROOTS = () => {
  const h = homedir();
  return [h, "/tmp", "/var/tmp", "/mnt/d", "/mnt/c/Users"].filter(Boolean);
};

export function assertReadablePath(absPath) {
  const path = resolve(expandHome(absPath));
  const roots = ALLOWED_ROOTS();
  const ok = roots.some((root) => {
    const r = resolve(root);
    return path === r || path.startsWith(r + sep) || path.startsWith(r + "/");
  });
  if (!ok) {
    const e = new Error("path outside allowed roots");
    e.code = "EACCES";
    throw e;
  }
  // Block path tricks
  if (path.includes("\0")) {
    const e = new Error("invalid path");
    e.code = "EINVAL";
    throw e;
  }
  return path;
}

function entryType(dirent, parent) {
  if (dirent.isDirectory()) return "dir";
  if (dirent.isSymbolicLink()) {
    try {
      const st = statSync(join(parent, dirent.name));
      return st.isDirectory() ? "dir" : "file";
    } catch {
      return "file";
    }
  }
  return "file";
}

function fileSize(parent, name) {
  try {
    return lstatSync(join(parent, name)).size;
  } catch {
    return undefined;
  }
}

/**
 * List a directory for phone autocomplete.
 * @param {string} absPath
 * @param {{ limit?: number, showHidden?: boolean }} [opts]
 * @returns {{ path: string, entries: Array<{ name: string, type: 'file'|'dir', size?: number }> }}
 */
export function listDir(absPath, { limit = 200, showHidden = false } = {}) {
  const path = assertReadablePath(absPath || homedir());
  let names;
  try {
    names = readdirSync(path, { withFileTypes: true });
  } catch (err) {
    const e = new Error(err?.message || "cannot read directory");
    e.code = err?.code || "EREAD";
    throw e;
  }

  /** @type {Array<{ name: string, type: 'file'|'dir', size?: number }>} */
  const entries = [];
  for (const d of names) {
    if (!showHidden && d.name.startsWith(".")) continue;
    const type = entryType(d, path);
    const rec = { name: d.name, type };
    if (type === "file") {
      const size = fileSize(path, d.name);
      if (size !== undefined) rec.size = size;
    }
    entries.push(rec);
  }

  entries.sort((a, b) => {
    if (a.type !== b.type) return a.type === "dir" ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  });

  return {
    path,
    entries: entries.length > limit ? entries.slice(0, limit) : entries,
  };
}

/**
 * Path autocomplete search.
 * - Absolute / ~ query: match basenames under the parent directory.
 * - Relative query: walk under cwd (depth ≤ 3) for basename prefix matches.
 * @param {string} query
 * @param {{ cwd?: string, limit?: number, showHidden?: boolean }} [opts]
 * @returns {Array<{ path: string, type: 'file'|'dir' }>}
 */
export function searchPaths(query, { cwd = homedir(), limit = 30, showHidden = false } = {}) {
  const q = String(query || "").trim();
  if (!q) return [];

  if (q.startsWith("/") || q.startsWith("~")) {
    return searchAbsolute(q, { limit, showHidden });
  }
  return searchRelative(q, resolve(expandHome(cwd || homedir())), { limit, showHidden });
}

function searchAbsolute(query, { limit, showHidden }) {
  const expanded = expandHome(query);
  let parent;
  let prefix;

  if (query.endsWith("/") || query.endsWith("\\")) {
    parent = assertReadablePath(expanded);
    prefix = "";
  } else {
    // /home/fer → parent=/home, prefix=fer
    const resolved = resolve(expanded);
    parent = assertReadablePath(dirname(resolved));
    prefix = basename(resolved);
  }

  /** @type {Array<{ path: string, type: 'file'|'dir' }>} */
  const results = [];
  let names;
  try {
    names = readdirSync(parent, { withFileTypes: true });
  } catch {
    return results;
  }

  const prefLower = prefix.toLowerCase();
  for (const d of names) {
    if (results.length >= limit) break;
    if (!showHidden && d.name.startsWith(".")) continue;
    if (prefix && !d.name.toLowerCase().startsWith(prefLower)) continue;
    const type = entryType(d, parent);
    results.push({ path: join(parent, d.name), type });
  }

  results.sort((a, b) => {
    if (a.type !== b.type) return a.type === "dir" ? -1 : 1;
    return basename(a.path).localeCompare(basename(b.path), undefined, { sensitivity: "base" });
  });
  return results.slice(0, limit);
}

function searchRelative(prefix, base, { limit, showHidden }) {
  /** @type {Array<{ path: string, type: 'file'|'dir' }>} */
  const results = [];
  const prefLower = prefix.toLowerCase();
  let safeBase;
  try {
    safeBase = assertReadablePath(base);
  } catch {
    return results;
  }

  function walk(dir, depth) {
    if (results.length >= limit || depth > 3) return;
    let names;
    try {
      names = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const d of names) {
      if (results.length >= limit) return;
      if (!showHidden && d.name.startsWith(".")) continue;
      const full = join(dir, d.name);
      const type = entryType(d, dir);
      if (d.name.toLowerCase().startsWith(prefLower)) {
        results.push({ path: full, type });
      }
      if (type === "dir" && depth < 3) walk(full, depth + 1);
    }
  }

  walk(safeBase, 1);
  return results;
}

/**
 * Read a small image (or any file) for the phone chat viewer.
 * Returns { path, mime, data: base64, size } or throws.
 */
export function readFileBase64(absPath, { maxBytes = MAX_FILE_BYTES } = {}) {
  const path = assertReadablePath(absPath);
  if (!existsSync(path)) {
    const e = new Error("file not found");
    e.code = "ENOENT";
    throw e;
  }
  let st;
  try {
    st = statSync(path);
  } catch (err) {
    const e = new Error(err?.message || "cannot stat");
    e.code = err?.code || "ESTAT";
    throw e;
  }
  if (!st.isFile()) {
    const e = new Error("not a file");
    e.code = "ENOTFILE";
    throw e;
  }
  if (st.size > maxBytes) {
    const e = new Error(`file too large (${st.size} > ${maxBytes})`);
    e.code = "ETOOBIG";
    throw e;
  }
  const buf = readFileSync(path);
  const ext = extname(path).toLowerCase();
  const mime =
    ext === ".png" ? "image/png"
    : ext === ".jpg" || ext === ".jpeg" ? "image/jpeg"
    : ext === ".gif" ? "image/gif"
    : ext === ".webp" ? "image/webp"
    : ext === ".heic" ? "image/heic"
    : "application/octet-stream";
  return {
    path,
    mime,
    size: buf.length,
    data: buf.toString("base64"),
    isImage: IMAGE_EXT.has(ext),
  };
}
