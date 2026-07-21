# TethrX Feras — features

## Shipped 2026-07-21 (big pack)

| Feature | Where |
|---------|--------|
| APNs key XF27A33VNY | config; auth OK on **sandbox** (prod needs Sandbox&Production key) |
| Dual-host APNs auto | bridge `apns.mjs` |
| CLI resume + full history import | `import-cli-history.mjs` |
| ACP image blocks + path fallback | messages API |
| ActivityKit push path | LiveActivity + activity-token |
| FS browse + @path search | `GET /api/fs`, `/api/fs/search` |
| cwd recents / bookmarks | `/api/cwd-recents` + chips + Browse sheet |
| Share URL scheme | `tethrx://share?text=` |
| ⌘↩ send, paste image | ChatView |
| Quiet hours | bridge config + Settings UI |
| Open PR + CI runs | git `action:pr`, `GET …/ci` |
| Running-only filter | SessionListView |
| Hermes APNs hook script | `tethrx-apns-session-end.sh` |

## Solid base
Live SSE, plan, approvals, multi-PC, dictation, snippets, git review, cost meter, Feras bridge URL

## APNs note
Key `XF27A33VNY` authenticates on `api.sandbox.push.apple.com`.  
TestFlight device tokens need **production**. If prod returns `BadEnvironmentKeyInToken`, recreate APNs key with **Sandbox & Production** (or Production) at developer.apple.com → Keys.

## Ship
```bash
cd ~/tethrx-feras && git add -A && git commit -m "feat: …" && git push
gh workflow run testflight.yml -R FerasMahmoud/tethrx-feras
```
