// Native push to the phone via Apple Push Notification service (APNs).
//
// Two auth modes (first that works wins):
//   1) Token auth — .p8 Auth Key with APNs service enabled + keyId + teamId
//   2) Certificate auth — combined PEM (push.crt + push.key) from Apple Push Services cert
//
// ASC API keys (App Store Connect Integrations) do NOT work for APNs → InvalidProviderToken.
// Create APNs Auth Key at: developer.apple.com/account/resources/authkeys
// Or run: gh workflow run apns-setup.yml  (tries cert path via ASC API)

import http2 from "node:http2";
import { createSign, createPrivateKey, X509Certificate } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const b64url = (x) => Buffer.from(x).toString("base64url");

export class Apns {
  constructor({ stateDir, keyPath, keyId, teamId, topic, certPemPath }) {
    this.devicesPath = join(stateDir, "devices.json");
    this.keyId = keyId || "";
    this.teamId = teamId || "";
    this.topic = topic || "uk.firashome.tethrx";
    this.keyPem = "";
    this.certPem = "";
    this.authMode = null; // "token" | "cert"
    this.enabled = false;
    this.lastError = null;

    // Prefer dedicated APNs .p8 token auth
    try {
      if (keyPath && keyId && teamId && existsSync(keyPath)) {
        this.keyPem = readFileSync(keyPath, "utf8");
        // Heuristic: ASC keys and APNs keys look the same; we only know after probe.
        this.authMode = "token";
        this.enabled = true;
      }
    } catch (e) {
      this.lastError = String(e);
    }

    // Certificate auth fallback (Apple Push Services SSL cert + private key PEM)
    const certPath = certPemPath || join(stateDir, "apns-client.pem");
    try {
      if (existsSync(certPath)) {
        this.certPem = readFileSync(certPath, "utf8");
        if (!this.enabled) {
          this.authMode = "cert";
          this.enabled = true;
        }
        // Keep cert available even if token mode is primary (probe may switch)
        this._certPath = certPath;
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
    } catch { return []; }
  }
  _save() {
    try { writeFileSync(this.devicesPath, JSON.stringify({ tokens: this.tokens }, null, 2), { mode: 0o600 }); }
    catch { /* best-effort */ }
  }

  /** Register a phone's APNs device token (hex). Returns false if malformed. */
  addDevice(token) {
    if (typeof token !== "string" || !/^[0-9a-fA-F]{40,256}$/.test(token)) return false;
    const t = token.toLowerCase();
    if (!this.tokens.includes(t)) { this.tokens.push(t); this._save(); }
    return true;
  }

  /** Cached provider JWT for token auth (valid up to 1h). */
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

  _connect() {
    // Production APNs
    if (this.authMode === "cert" && this.certPem) {
      return http2.connect("https://api.push.apple.com", {
        // mTLS: full PEM with cert + key
        cert: this.certPem,
        key: this.certPem,
      });
    }
    return http2.connect("https://api.push.apple.com");
  }

  _sendOne(client, token, payloadStr, headersExtra = {}) {
    return new Promise((resolve) => {
      const headers = {
        ":method": "POST",
        ":path": `/3/device/${token}`,
        "apns-topic": headersExtra.topic || this.topic,
        "apns-push-type": headersExtra.pushType || "alert",
        "apns-priority": String(headersExtra.priority || "10"),
        ...headersExtra.extra,
      };
      if (this.authMode === "token") {
        try {
          headers.authorization = `bearer ${this._providerToken()}`;
        } catch (e) {
          return resolve({ token, status: 0, body: String(e) });
        }
      }
      const req = client.request(headers);
      let status = 0, body = "";
      req.setEncoding("utf8");
      req.on("response", (h) => { status = h[":status"]; });
      req.on("data", (d) => { body += d; });
      req.on("end", () => resolve({ token, status, body }));
      req.on("error", (e) => resolve({ token, status: 0, body: String(e) }));
      req.end(payloadStr);
    });
  }

  /** Switch to cert mode if token auth is rejected (InvalidProviderToken). */
  _maybeFallbackToCert(probeBody) {
    if (this.authMode !== "token") return false;
    if (!this.certPem && this._certPath && existsSync(this._certPath)) {
      try { this.certPem = readFileSync(this._certPath, "utf8"); } catch { /* */ }
    }
    if (!this.certPem) return false;
    if (/InvalidProviderToken|ExpiredProviderToken/.test(probeBody || "")) {
      this.authMode = "cert";
      return true;
    }
    return false;
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
    const client = this._connect();
    client.on("error", () => {});
    try {
      let results = await Promise.all(this.tokens.map((t) => this._sendOne(client, t, payloadStr)));
      // If all failed with InvalidProviderToken and we have a cert, retry once in cert mode
      if (
        results.every((r) => r.status === 403 || /InvalidProviderToken/.test(r.body)) &&
        this._maybeFallbackToCert(results[0]?.body)
      ) {
        try { client.close(); } catch { /* */ }
        const client2 = this._connect();
        client2.on("error", () => {});
        try {
          results = await Promise.all(this.tokens.map((t) => this._sendOne(client2, t, payloadStr)));
        } finally {
          try { client2.close(); } catch { /* */ }
        }
        return { ok: results.some((r) => r.status >= 200 && r.status < 300), results, authMode: this.authMode };
      }
      const dead = new Set(
        results.filter((r) => r.status === 410 || /BadDeviceToken|Unregistered/.test(r.body)).map((r) => r.token)
      );
      if (dead.size) { this.tokens = this.tokens.filter((t) => !dead.has(t)); this._save(); }
      return { ok: results.some((r) => r.status >= 200 && r.status < 300), results, authMode: this.authMode };
    } catch (e) {
      return { ok: false, reason: "send", error: String(e) };
    } finally { try { client.close(); } catch { /* ignore */ } }
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
    const client = this._connect();
    client.on("error", () => {});
    try {
      const r = await this._sendOne(client, token, payloadStr, {
        topic,
        pushType: "liveactivity",
        priority: "10",
      });
      if (r.status === 410 || /BadDeviceToken|Unregistered/.test(r.body)) {
        session.activityPushToken = null;
      }
      if (r.status === 403 && this._maybeFallbackToCert(r.body)) {
        try { client.close(); } catch { /* */ }
        const c2 = this._connect();
        try {
          const r2 = await this._sendOne(c2, token, payloadStr, {
            topic, pushType: "liveactivity", priority: "10",
          });
          return { ok: r2.status >= 200 && r2.status < 300, status: r2.status, body: r2.body, authMode: this.authMode };
        } finally { try { c2.close(); } catch { /* */ } }
      }
      return { ok: r.status >= 200 && r.status < 300, status: r.status, body: r.body, authMode: this.authMode };
    } catch (e) {
      return { ok: false, reason: "send", error: String(e) };
    } finally { try { client.close(); } catch { /* ignore */ } }
  }

  /**
   * Probe whether auth is accepted by APNs.
   * BadDeviceToken on fake token = auth OK.
   * InvalidProviderToken = wrong key type (ASC key used as APNs).
   */
  async probe() {
    if (!this.enabled) {
      return {
        ok: false,
        reason: "disabled",
        hint: "Set apns.keyPath+keyId+teamId (APNs Auth Key .p8) or place apns-client.pem in stateDir",
      };
    }
    const fake = "a".repeat(64);
    const client = this._connect();
    client.on("error", () => {});
    try {
      let r = await this._sendOne(client, fake, JSON.stringify({
        aps: { alert: { title: "probe", body: "probe" } },
      }));
      if ((r.status === 403 || /InvalidProviderToken/.test(r.body)) && this._maybeFallbackToCert(r.body)) {
        try { client.close(); } catch { /* */ }
        const c2 = this._connect();
        try {
          r = await this._sendOne(c2, fake, JSON.stringify({
            aps: { alert: { title: "probe", body: "probe" } },
          }));
        } finally { try { c2.close(); } catch { /* */ } }
      }
      const body = r.body || "";
      const authOk = r.status === 400 || /BadDeviceToken|DeviceTokenNotForTopic|TopicDisallowed/.test(body);
      const authBad = r.status === 403 || /InvalidProviderToken|ExpiredProviderToken/.test(body);
      return {
        ok: authOk,
        status: r.status,
        body,
        authOk,
        authBad,
        authMode: this.authMode,
        topic: this.topic,
        keyId: this.keyId,
        teamId: this.teamId,
        hasCert: !!this.certPem,
        hint: authBad
          ? "Key is not an APNs Auth Key. Create one at developer.apple.com → Keys → enable Apple Push Notifications. Or run: gh workflow run apns-setup.yml"
          : authOk
            ? "APNs auth OK"
            : `Unexpected status ${r.status}`,
      };
    } catch (e) {
      return { ok: false, reason: "network", error: String(e) };
    } finally { try { client.close(); } catch { /* ignore */ } }
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
  });
}
