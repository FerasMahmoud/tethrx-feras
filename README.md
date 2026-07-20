# TethrX · Feras

Personal fork of [Myrhex-x/TethrX](https://github.com/Myrhex-x/TethrX) — **your phone controls Grok Build on Feras-PC**.

| | |
|--|--|
| **Bridge (always on)** | `https://tethrx.firashome.uk` → `127.0.0.1:4180` on the PC |
| **Bundle ID** | `uk.firashome.tethrx` |
| **Team** | `3V4NW789C6` |
| **Display name** | TethrX Feras |

## Phone setup

1. Install from **your** TestFlight build (not the public TethrX link).
2. Address is pre-filled: `https://tethrx.firashome.uk`
3. Paste pairing token once (from PC: `cat ~/.tethrx-pair-token` or open `http://localhost:4180/pair`).
4. Token stays in Keychain.

## PC bridge

```bash
systemctl --user status tethrx-bridge
# public URL via Cloudflare (not Pinggy — Pinggy token is reserved for SSH)
```

## TestFlight CI

```bash
gh workflow run testflight.yml -R FerasMahmoud/tethrx-feras
```

Secrets (same family as `firashome-todo`):  
`APP_STORE_CONNECT_*`, `MATCH_*`

## License

Apache-2.0 (upstream TethrX).
