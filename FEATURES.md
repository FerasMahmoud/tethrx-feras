# TethrX Feras — feature roadmap

Deep audit 2026-07-21 (iOS + bridge + web brainstorm).  
Bridge = text-only remote for Grok Build. Phone = control plane.

## Shipped this turn (client-only, no bridge change)

| Feature | Where |
|---------|--------|
| **Paste** chip in composer | `ChatView.swift` — clipboard → draft (append if non-empty) |
| **Expand** composer | taller `lineLimit` for long pastes |
| **Clear** draft + char count | composer chips |
| **Draft persistence** | per-session `UserDefaults` key `draft.<sessionId>` |
| **Paste token / URL** on pair | `PairingView` + `AddComputerSheet` |
| **Siri cold-start URL** | `IntentBridge` falls back to `FerasDefaults.bridgeURL` |

## Already solid (keep)

- Live SSE (thoughts, tools, diffs)
- Queue while busy + stop
- Plan mode + tool approvals
- Dictation, snippets, multi-PC
- Git review / commit / discard
- Feras default bridge `https://tethrx.firashome.uk`

## Next (priority for Feras iPad)

| # | Feature | Effort | Needs bridge? |
|---|---------|--------|----------------|
| 1 | Hardware keyboard: Cmd-Return send | S | No |
| 2 | Share Extension (share text → session) | M | No (text only) |
| 3 | Re-enable Push + App Groups entitlements | M | ASC capabilities |
| 4 | cwd recents / bookmarks | S | No |
| 5 | Edit queued follow-ups | S | No |
| 6 | Screenshot / image → Grok | L | **Yes** (multimodal ACP) |
| 7 | File upload into session cwd | L | **Yes** |
| 8 | Working directory browser | M | Optional list API |

## Bridge gaps (rich input)

`POST /api/sessions/:id/messages` accepts **only** `{ text: string }`.  
Images/files need new content blocks in ACP `session/prompt` + upload endpoint.

## Brainstorm (web + remote-agent UX 2026)

- **Paste-first remote**: Termius/SSH users live in clipboard — one-tap paste is table stakes.
- **Approve from lock screen**: needs APNs + public URL (we have public URL; entitlements empty).
- **Share sheet in**: select error log in Safari/Files → Share → TethrX.
- **Queue as kanban**: multiple follow-ups while agent works (already partial).
- **Context meter always visible**: already in nav subtitle.
- **Don't rebuild ChatGPT**: stay terminal-native (mono, plan, tools).

## Ship loop

```bash
# after iOS edits
cd ~/tethrx-feras && git add -A && git commit -m "feat: …" && git push
gh workflow run testflight.yml -R FerasMahmoud/tethrx-feras
```
