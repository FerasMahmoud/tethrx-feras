# TethrX Feras — feature roadmap

Deep ship 2026-07-21: APNs-only push, UI polish, CLI resume, multimodal path.

## Shipped this turn

| Feature | Where |
|---------|--------|
| **Paste** on Plan / Effort / Auto-approve row | `ChatView.swift` — Expand removed |
| **Clear** when draft non-empty | same control row |
| **Draft persistence** | per-session `UserDefaults` |
| **APNs only** (no ntfy) | bridge `pushNotify` + `~/.grok-remote/config.json` |
| **Push + App Groups entitlements** | `GrokRemote.entitlements` + widget |
| **Device register** | `POST /api/devices` → APNs topic `uk.firashome.tethrx` |
| **Grok CLI resume list** | `GET /api/grok-sessions` + app section |
| **Resume via ACP session/load** | `POST /api/sessions` + `resumeGrokSessionId` |
| **Image attach** | PhotosPicker → bridge writes `.tethrx-uploads/` + path in prompt |
| **Live Activity** | foreground Island updates on turn/tool/complete |
| **Paste token / URL** on pair | PairingView + AddComputerSheet |
| **Siri cold-start URL** | IntentBridge → FerasDefaults.bridgeURL |

## Already solid (keep)

- Live SSE (thoughts, tools, diffs)
- Queue while busy + stop
- Plan mode + tool approvals
- Dictation, snippets, multi-PC
- Git review / commit / discard
- Feras default bridge `https://tethrx.firashome.uk`

## Notifications (locked)

- **In-app / APNs only** — ntfy fully removed from push path and live config
- Phone must enable Push in Settings once; token registers on connect
- Approval pushes use category `PERMISSION` (Approve / Reject actions)

## Next (optional)

| # | Feature | Effort |
|---|---------|--------|
| 1 | Hardware keyboard Cmd-Return send | S |
| 2 | Share Extension (text → session) | M |
| 3 | True ACP image content blocks (if grok supports) | L |
| 4 | ActivityKit push for background Island | M |
| 5 | cwd recents / bookmarks | S |

## Ship loop

```bash
cd ~/tethrx-feras && git add -A && git commit -m "feat: …" && git push
gh workflow run testflight.yml -R FerasMahmoud/tethrx-feras
```
