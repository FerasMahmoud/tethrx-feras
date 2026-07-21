# TethrX Feras — features

## Shipped

### Core
- Live SSE (thoughts, tools, diffs)
- Plan mode, effort, auto-approve
- Tool approve/reject (+ lock-screen category when APNs works)
- Queue while busy + stop
- Dictation, snippets, multi-PC
- Git review / commit / discard / **Open PR**
- **CI runs** in session details (`gh run list`)
- Cost / context meter
- Feras bridge `https://tethrx.firashome.uk`

### Notifications
- APNs only (no ntfy)
- Device register, probe, test push
- Dual host auto (production + sandbox)
- Quiet hours (bridge `quietHours` + app Settings)
- Live Activity (FG + ActivityKit token path)
- Hermes finish script → `tethrx-apns-notify`

### Sessions
- Grok CLI resume list + **full history import**
- Running-only filter
- cwd recents chips + **Browse** sheet (`/api/fs`)
- `@path` autocomplete (`/api/fs/search`)

### Input
- Paste on Plan row (Expand removed)
- Draft persistence
- PhotosPicker images + **Paste image** from clipboard
- ACP image blocks + path fallback
- Cmd-Return send (keyboard shortcut)
- `tethrx://share?text=` deep link (+ pair URL)

### Ship
```bash
cd ~/tethrx-feras && git add -A && git commit -m "feat: …" && git push
gh workflow run testflight.yml -R FerasMahmoud/tethrx-feras
```

## APNs note (2026-07-21)
- Key `XF27A33VNY` from Drive: **auth OK on sandbox**
- TestFlight device token is **production** → needs key that works on `api.push.apple.com`
- If production returns `BadEnvironmentKeyInToken`, recreate APNs key with **Sandbox & Production** at developer.apple.com → Keys
- Install: `install-apns-key AuthKey_XXX.p8`

## Still optional later
- Full Share Extension target (URL scheme covers share-in)
- Android / PWA
- Subagent tree
- Dual-surface CLI leader mode
