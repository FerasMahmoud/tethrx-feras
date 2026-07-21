// Native push via APNs — token (.p8) or cert PEM.
// Environment: production | sandbox | auto (try both hosts).
// TestFlight device tokens need production; sandbox-only keys return BadEnvironmentKeyInToken on prod.

import http2 from "node:http2";
import { createSign } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const b64url = (x) => Buffer.from(x).toString("base64url");

export class Apns {
  constructor({ stateDir, keyPath, keyId, teamId, topic, certPemPath, environment }) {
    this.devicesPath = join(stateDir, "devices.json");
    this.keyId = keyId || "";
    this.teamId = teamId || "";
    this.topic = topic || "uk.firashome.tethrx";
    this.environment = (environment || process.env.GROK_REMOTE_APNS_ENV || "auto").toLowerCase();
    this.keyPem = "";
    this.certPem = "";
    this.authMode = null;
    this.enabled = false;
    this.lastError = null;
    this._certPath = null;

    try {
      if (keyPath && keyId && teamId && existsSync(keyPath)) {
        this.keyPem = readFileSync(keyPath, "utf8");
        this.authMode = "token";
        this.enabled = true;
      }
    } catch (e) {
      this.lastError = String(e);
    }

    const certPath = certPemPath || join(stateDir, "apns-client.pem");
    try {
      if (existsSync(certPath)) {
        this.certPem = readFileSync(certPath, "utf8");
        this._certPath = certPath;
        if (!this.enabled) {
          this.authMode = "cert";
          this.enabled = true;
        }
      }
    } catch (e) {
      this.lastError = String(e);
    }

    this.tokens = this._load();
    this._jwt = null;
    this._jwtAt = 0;
  }

  _load() {
    try {
      const d = JSON.parse(readFileSync(this.devicesPath, "utf8"));
      return Array.isArray(d.tokens) ? d.tokens : [];
    } catch {
      return [];
    }
  }
  _save() {
    try {
      writeFileSync(this.devicesPath, JSON.stringify({ tokens: this.tokens }, null, 2), { mode: 0o600 });
    } catch { /* best-effort */ }
  }

  addDevice(token) {
    if (typeof token !== "string" || !/^[0-9a-fA-F]{40,256}$/.test(token)) return false;
    const t = token.toLowerCase();
    if (!this.tokens.includes(t)) {
      this.tokens.push(t);
      this._save();
    }
    return true;
  }

  _providerToken() {
    const now = Math.floor(Date.now() / 1000);
    if (this._jwt && now - this._jwtAt < 2400) return this._jwt;
    const header = b64url(JSON.stringify({ alg: "ES256", kid: this.keyId }));
    const payload = b64url(JSON.stringify({ iss: this.teamId, iat: now }));
    const input = `${header}.${payload}`;
    const sig = createSign("SHA256").update(input).sign({ key: this.keyPem, dsaEncoding: "ieee-p1363" });
    this._jwt = `${input}.${sig.toString("base64url")}`;
    this._jwtAt = now;
    return this._jwt;
  }

  _hosts() {
    if (this.environment === "sandbox") return ["api.sandbox.push.apple.com"];
    if (this.environment === "production") return ["api.push.apple.com"];
    return ["api.push.apple.com", "api.sandbox.push.apple.com"];
  }

  _connect(host) {
    if (this.authMode === "cert" && this.certPem) {
      return http2.connect(`https://${host}`, { cert: this.certPem, key: this.certPem });
    }
    return http2.connect(`https://${host}`);
  }

  _sendOne(client, token, payloadStr, headersExtra = {}) {
    return new Promise((resolve) => {
      const headers = {
        ":method": "POST",
        ":path": `/3/device/${token}`,
        "apns-topic": headersExtra.topic || this.topic,
        "apns-push-type": headersExtra.pushType || "alert",
        "apns-priority": String(headersExtra.priority || "10"),
      };
      if (this.authMode === "token") {
        try {
          headers.authorization = `bearer ${this._providerToken()}`;
        } catch (e) {
          return resolve({ token, status: 0, body: String(e) });
        }
      }
      const req = client.request(headers);
      let status = 0,
        body = "";
      req.setEncoding("utf8");
      req.on("response", (h) => {
        status = h[":status"];
      });
      req.on("data", (d) => {
        body += d;
      });
      req.on("end", () => resolve({ token, status, body }));
      req.on("error", (e) => resolve({ token, status: 0, body: String(e) }));
      req.end(payloadStr);
    });
  }

  /** Try each host until one accepts the provider token / delivers. */
  async _sendAllHosts(tokens, payloadStr, headersExtra = {}) {
    let last = [];
    for (const host of this._hosts()) {
      const client = this._connect(host);
      client.on("error", () => {});
      try {
        const results = await Promise.all(tokens.map((t) => this._sendOne(client, t, payloadStr, headersExtra)));
        last = results.map((r) => ({ ...r, host }));
        // Provider token wrong for this env — try next host
        if (results.every((r) => r.status === 403 && /BadEnvironmentKeyInToken|InvalidProviderToken/.test(r.body))) {
          continue;
        }
        // At least one non-env-error response — use this host
        return { host, results: last };
      } finally {
        try {
          client.close();
        } catch { /* */ }
      }
    }
    return { host: this._hosts().slice(-1)[0], results: last };
  }

  async send({ title, body, sessionId, category, requestId, allowOptionId, rejectOptionId }) {
    if (!this.enabled || this.tokens.length === 0) return { ok: false, reason: "no_devices" };
    const payloadStr = JSON.stringify({
      aps: {
        alert: { title, body },
        sound: "default",
        "thread-id": sessionId || "",
        ...(category ? { category } : {}),
      },
      sessionId: sessionId || "",
      ...(requestId ? { requestId } : {}),
      ...(allowOptionId ? { allowOptionId } : {}),
      ...(rejectOptionId ? { rejectOptionId } : {}),
    });
    try {
      const { host, results } = await this._sendAllHosts(this.tokens, payloadStr);
      // Only prune tokens APNs says are gone forever (410 / Unregistered).
      // Do NOT prune BadDeviceToken — that often means wrong environment (prod token on sandbox).
      const dead = new Set(
        results
          .filter((r) => r.status === 410 || /"reason"\s*:\s*"Unregistered"/.test(r.body || ""))
          .map((r) => r.token)
      );
      if (dead.size) {
        this.tokens = this.tokens.filter((t) => !dead.has(t));
        this._save();
      }
      const ok = results.some((r) => r.status >= 200 && r.status < 300);
      return { ok, host, results, authMode: this.authMode };
    } catch (e) {
      return { ok: false, reason: "send", error: String(e) };
    }
  }

  async sendLiveActivity(session, { phase = "working", detail = "", event = "update" } = {}) {
    const token = session?.activityPushToken;
    if (!this.enabled || !token) return { ok: false, reason: "no_activity_token" };
    const topic = `${this.topic}.push-type.liveactivity`;
    const payloadStr = JSON.stringify({
      aps: {
        timestamp: Math.floor(Date.now() / 1000),
        event,
        "content-state": {
          phase: String(phase || "working"),
          detail: String(detail || "").slice(0, 80),
        },
        ...(event === "end" ? { "dismissal-date": Math.floor(Date.now() / 1000) + 4 } : {}),
      },
    });
    try {
      const { host, results } = await this._sendAllHosts([token], payloadStr, {
        topic,
        pushType: "liveactivity",
        priority: "10",
      });
      const r = results[0] || {};
      if (r.status === 410 || /BadDeviceToken|Unregistered/.test(r.body || "")) {
        session.activityPushToken = null;
      }
      return { ok: r.status >= 200 && r.status < 300, status: r.status, body: r.body, host, authMode: this.authMode };
    } catch (e) {
      return { ok: false, reason: "send", error: String(e) };
    }
  }

  async probe() {
    if (!this.enabled) {
      return {
        ok: false,
        reason: "disabled",
        hint: "Set apns.keyPath+keyId+teamId (APNs Auth Key .p8)",
      };
    }
    const fake = "a".repeat(64);
    const payloadStr = JSON.stringify({ aps: { alert: { title: "probe", body: "probe" } } });
    try {
      const { host, results } = await this._sendAllHosts([fake], payloadStr);
      const r = results[0] || { status: 0, body: "" };
      const body = r.body || "";
      const authOk = r.status === 400 || /BadDeviceToken|DeviceTokenNotForTopic|TopicDisallowed/.test(body);
      const authBad = r.status === 403 || /InvalidProviderToken|ExpiredProviderToken|BadEnvironmentKeyInToken/.test(body);
      return {
        ok: authOk,
        status: r.status,
        body,
        authOk,
        authBad,
        authMode: this.authMode,
        host,
        environment: this.environment,
        topic: this.topic,
        keyId: this.keyId,
        teamId: this.teamId,
        hasCert: !!this.certPem,
        hint: authOk
          ? `APNs auth OK via ${host}`
          : authBad
            ? `Auth rejected on tried hosts. Key may be sandbox-only while TestFlight needs production (or wrong team). Create key with Sandbox & Production at developer.apple.com → Keys → APNs.`
            : `Unexpected status ${r.status} on ${host}`,
      };
    } catch (e) {
      return { ok: false, reason: "network", error: String(e) };
    }
  }
}

export function loadApns(config) {
  const a = config.apns || {};
  return new Apns({
    stateDir: config.stateDir,
    keyPath: a.keyPath || process.env.GROK_REMOTE_APNS_KEY || "",
    keyId: a.keyId || process.env.GROK_REMOTE_APNS_KEY_ID || "",
    teamId: a.teamId || process.env.GROK_REMOTE_APNS_TEAM_ID || "",
    topic: a.topic || process.env.GROK_REMOTE_APNS_TOPIC || "uk.firashome.tethrx",
    certPemPath: a.certPemPath || process.env.GROK_REMOTE_APNS_CERT_PEM || "",
    environment: a.environment || process.env.GROK_REMOTE_APNS_ENV || "auto",
  });
}
