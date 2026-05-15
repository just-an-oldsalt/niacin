# Niacin — TODO

Working list. Effort estimates: S / M / L. ★ = distinctive vs. competitors (Amphetamine / KeepingYouAwake / Lungo / Theine / Caffeine).

---

## v2.1 — remaining before cut

- **Better menu bar icon** ★ — currently `cup.and.saucer` / `cup.and.saucer.fill` SF Symbols. Replace with a custom template PNG/PDF in the asset catalogue (must be `isTemplate = true` so dark/light menu bars both tint correctly). A pill / vitamin-capsule glyph leans into the "niacin = vitamin B3" name. Optional: countdown badge or timer ring while a timed session is running. (S–M)
- **Version bump + release** — `MARKETING_VERSION` 2.0 → 2.1, `CURRENT_PROJECT_VERSION` 11 → 12; run `scripts/release.sh 2.1`; tag and publish GitHub release for the Enterprise channel; archive the MAS configuration in Xcode and submit to App Store Connect. Full runbook in `RELEASING.md`. (S)
- **MAS metadata** — update App Store Connect subtitle to avoid Apple trademark terms (no "Mac" / "macOS") — see `RELEASING.md`. Generate App Store screenshots, write the description, fill in the localised metadata. (S)

---

## v2.2 — Developer CLI

Stream 3 follow-through. The `niacin://` URL scheme + `niacin run` wrapper shipped in v2.0; this is the rest.

- **Full Swift `niacin` CLI** — feature parity with the menu (`niacin status`, `niacin activate 30m`, `niacin deactivate`, `niacin watch <pid>`). Pairs with the existing `scripts/niacin run` shell wrapper, which keeps its shape for backwards compatibility. (M)
- **Build-tool / container-runtime auto-detect** — auto-stay-awake while `xcodebuild`, `swift build`, `gradle` daemon, `docker buildx`, `webpack --watch`, `vite`, `cargo build`, `bazel`, `make`, OrbStack/Colima with active containers are running. Configurable allowlist; trivial extension of the existing `ProcessWatcher` infrastructure. (M)
- **AppleScript dictionary** — expose `activate for X minutes` / `deactivate` as scriptable verbs. (S)
- **Shortcuts.app actions** — first-class Intents for Activate / Deactivate / Status. (S–M)
- **Bind-to-PID** — drag a process from Activity Monitor onto the menu bar icon → "stay awake until this PID exits". Replicates `caffeinate -w PID` with UI. (M)
- **xbar / SwiftBar / Übersicht status export** — emit a JSON status file at `~/Library/Caches/com.oldsalt.niacin/status.json` so custom menu bar tools can render Niacin state inline. (S)
- **Charging-state trigger** — "Stay awake only while plugged in". Covers the laptop-on-couch case where mains-power is the right signal, not battery level. (S)

---

## v2.3 — Enterprise depth

- **Maintenance-window mode** — managed key `maintenanceWindow: { start, end, weekdays }` defining time slots where Niacin force-activates blind. Pairs with `forceActiveDuringDeploys` for "stay awake during the deploy IF it falls inside the window." (M)
- **Wake-from-sleep for scheduled deploys** — register `pmset schedule wake` from a managed key so Niacin can wake the device for a deploy window. Coordinates with macOS Power Nap. (M)
- **Signed-release CI workflow** — tag-triggered GitHub Action lifting `scripts/release.sh` once the Developer ID cert + notarytool API key can be loaded from secrets. Required secrets: `DEVELOPER_ID_P12` + `DEVELOPER_ID_P12_PASSWORD`, plus `APP_STORE_CONNECT_KEY_ID` / `ISSUER_ID` / `API_KEY`. (M)
- **"Safe to sleep" lock-screen badge** — when nothing is running and no maintenance window is active, surface a small lock-screen indicator. Inverts the model — IT teams see when machines are reclaim-ready. (L, optional)

---

## v2.4 — AI workstation depth

Process-presence detection + Ollama active-inference shipped in v2.0. Generalised HTTP probe registry (LM Studio, llama.cpp, text-generation-webui, ComfyUI) + MCP server shipped in v2.1. This is the deeper trigger work.

- **GPU / Neural Engine load trigger** — sample via `powermetrics --samplers gpu_power,ane_power` or IOKit. Stay awake while ANE or GPU > threshold for sustained period. Faster signal than CPU for AI workloads. (M–L)
- **Memory-pressure trigger** — wired-pages > N GB or sustained memory pressure indicates a model is loaded. Faster signal than process detection. (M)
- **"AI workstation mode" preset** — one-click profile: indefinite activation, system-stays-awake but display-can-sleep, ignores lid close, "AI training in progress" tooltip. (S)
- **Cool-down after long workloads** — when an AI session ends, schedule N-min cool-down before allowing sleep so fans spin down before thermal pressure peaks during sleep. Status: "5m cool-down active before sleep allowed". (S)
- **Thermal observability** — surface in tooltip when CPU/GPU sustained > 90°C for 10+ min. Doesn't change behaviour, just informs. AI on fanless minis can quietly thermal-throttle. (S)
- **Notification when long jobs complete** — when a watched AI process exits, fire a UserNotification with sound. "Ollama has been idle for 5 min. Niacin can let the system sleep." (S)
- **Battery-protective AI mode** — refuse force-activation triggers when on battery + battery < 50%, with an explicit override. AI inference on battery is brutal; a guardrail for laptop AI users. (S)
- **MCP transport: stdio proxy** — small standalone binary (Homebrew distribution) that bridges stdio MCP clients to the HTTP server. For clients that don't yet speak HTTP transport. (S–M)

---

## v2.x — QoL backlog

Cross-cutting items that don't fit cleanly into one stream.

- **Global hotkey to toggle** — quick activation without opening the menu (configurable, MDM-lockable). (S)
- **Custom user durations** — let users add their own preset alongside the defaults (still subject to `maxDurationSeconds`). (S)
- **Auto-deactivate on low battery** — common request for laptop users; trivial via `IOPSCopyPowerSourcesInfo`. Pairs with the battery-protective AI mode. (S)
- **Schedule windows** — "always awake 09:00–17:00 on weekdays." Useful for kiosks, also MDM-controllable. Pairs with maintenance-window mode. (M)
- **Extend / snooze a running session** — add 15 min without deactivating first. (S)
- **Lid-close intent memory** — if you had an active session and closed the lid, offer one-click resume on re-open ("Resume your 1h 30m session?"). Inverts the usual lid-close-kills-everything pattern. (S)
- **Activity histogram / weekly stats** — "You kept your Mac awake 14 h this week, mostly between 10:00 and 16:00." In-memory only, no tracking, no storage. Surprisingly engaging. (M)

---

## Localization release (separate cut)

- **ja and zh-Hans translations** — deferred from the v1.2 localization push. Both deserve a native review and have layout/font implications (Japanese tends to run wider, Chinese narrower; Japanese has only an `other` plural form).
- **Native review of fr/de/es/it translations** — shipped from a fluent generalist, not a professional translator. Most likely nitpicks: the menu-bar status fragments ("screen can sleep", "screen stays on") which sit awkwardly mid-sentence in some Romance constructions.

---

## Polish & UX

- **First-launch onboarding sheet** — short explainer for non-IT users; suppressed when `activateOnLaunch` is managed.
- **VoiceOver labels** on menu items and the menu bar icon — currently nothing read out for assistive tech.
- **Settings window resizability / layout pass** — the fixed `width: 380, height: 460` (was 340 pre-v2.0; bumped to fit the Auto-activation section) is tight in German. Once ja/zh-Hans land it'll need to flex.

---

## Code health

- (nothing pressing — Sparkle/sandbox tension dissolved in v2.1; Enterprise + MAS configurations now coexist in a single target via `MAS_BUILD` compilation condition.)

---

## Shipped in v2.1 (for the changelog)

For the release notes:

- ★ **MCP server** — Niacin exposes a localhost-only Model Context Protocol endpoint so AI agents (Claude Desktop, Claude Code, Cursor) can call `keep_awake`, `release_awake`, and `status` directly. Bearer-token auth, Keychain-stored. Opt-in via Settings. The single way agents drive keep-awake — replaces v2.0's process-scan-for-AI-runtimes heuristic.
- ★ **One sandboxed build, two distribution channels.** Same binary ships as GitHub `.dmg`/`.pkg` (Developer-ID signed) and through the Mac App Store. App Sandbox always on, `network.server` for the MCP listener, no other elevated entitlements.
- **Sparkle removal** — auto-update via Sparkle replaced by the App Store's mechanism (for users on the MAS build) or IT-managed pushes (for users on the GitHub channel). Drops EdDSA key management, appcast hosting, and ~300 lines of auto-update plumbing.
- **AI runtime auto-detect retired** — the `aiRuntimeAutoAwake` managed key, the Settings toggle, the hardcoded AI process list, the HTTP probe registry, and the Ollama active-inference probe are all gone.
- **ProcessWatcher retired** — `forceActiveDuringDeploys` and `forceActiveDuringApps` managed keys are gone. `sysctl(KERN_PROC_ALL)` is sandbox-forbidden, and the IT use case ("don't sleep during overnight deploys") is better served by `pmset schedule wake` from MDM.
- **Menu UI for MCP sessions** — when an agent holds a `keep_awake`, the menu shows "Active for: · MCP: <client> · <remaining> — release" with a click-to-release control. Menu bar countdown picks the soonest deadline across user-initiated and MCP-initiated holds.
- README + RELEASING.md rewritten around the single-build, dual-channel model.

## Shipped in v2.0 (for the changelog)

For the release notes:

- ★ `niacin://` URL scheme — every automation tool the user already owns (Calendar reminders, Shortcuts, Stream Deck, webhooks) instantly becomes a Niacin trigger
- ★ `niacin run -- <command>` wrapper — replaces `caffeinate -i ./long-job.sh` with a version that surfaces in the menu bar and auto-deactivates on exit
- ★ AI runtime auto-detect (Ollama, LM Studio, llama.cpp, MLX, ComfyUI, InvokeAI, Stable Diffusion, vLLM, mistralrs) — off by default; opt in via Settings or MDM
- ★ Ollama active-inference probe via `/api/ps` — drops force-active 5 min after the last model unloads from VRAM
- ★ `forceActiveDuringDeploys` managed key — IT-deploy daemons silently keep the device awake mid-deploy (jamf, installd, softwareupdated, munki, IntuneMdmAgent, mdmclient, Installer)
- `forceActiveDuringApps` managed key — same shape for general apps (Zoom, Teams, OBS, etc.)
- MDM audit log via `os.Logger` — `force-active begin/end reason=… matches=…` greppable via `log show`
- Gentle countdown end — last 30 s turns orange in the menu bar; optional sound (`warnSoundOnExpiry`)
- Sample `.mobileconfig` in `examples/` for JAMF/Kandji/Mosyle/Intune deployment
- README "For IT admins" section
- Info.plist Copy Bundle Resources double-listing fixed
