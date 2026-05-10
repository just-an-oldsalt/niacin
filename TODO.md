# niacin — TODO

A working list. Roughly grouped; effort estimates are S / M / L; ★ marks ideas that are particularly distinctive vs. competitors (Amphetamine / KeepingYouAwake / Lungo / Theine / Caffeine).

---

## Priorities (Richard)

### 1. Better menu bar icon
Currently `cup.and.saucer` / `cup.and.saucer.fill` SF Symbols. Options:
- Custom template PNG/PDF in the asset catalogue (monochrome, auto-tints to menu bar colour)
- A pill / vitamin-capsule glyph would lean into the "niacin = vitamin B3" name
- Active state: solid fill or subtle pulse animation; inactive: outlined
- Optional: small countdown badge or timer ring while a timed session is running
- Make sure the asset is a true template image (`isTemplate = true`) so dark/light menu bars both render correctly

### 2. Capitalize "Niacin" everywhere user-facing
Audit found mixed casing. Decide on **Niacin** as the canonical proper-noun spelling, then:
- `README.md` heading and prose (currently lowercase "niacin" throughout)
- `Info.plist` `CFBundleDisplayName` / `CFBundleName` (verify in Xcode build settings — currently the target/product name is `niacin`)
- About-window app name (driven by bundle display name)
- Comments and doc-strings in source (cosmetic but consistent)
- Leave lowercase only where it is a real identifier: bundle ID `com.oldsalt.niacin`, file paths, the Swift module/product name (renaming the product is a bigger surgery — keep separate)

---

## Primary feature streams (post-v1.6)

The next chapter of Niacin focuses on three audiences whose needs are under-served by every existing competitor. Each stream has high-leverage flagship items at the top, smaller polish items below.

### Stream 1 — Enterprise / IT-managed deployment

Niacin's biggest existing differentiator is live MDM-managed policy. Lean into the unattended-deploy use case where IT pushes a software update overnight and needs the device to stay awake without user involvement.

- **`forceActiveDuringApps` managed key** — array of process-name patterns. When any matches a running process, Niacin force-activates regardless of user state. Subsumes the older "Activate while specific apps are running" item but specifically MDM-controllable. (M)
- **`forceActiveDuringDeploys` managed key** ★ — separate array for IT-deploy daemons (`jamf`, `installd`, `softwareupdated`, `munki`, `IntuneMdmAgent`, `mdmclient`, `Installer`). Force-activates with **no visible UI flicker** so the user doesn't see anything change while a JAMF deploy completes overnight. (M)
- **MDM telemetry / audit log** — append-only structured `os.Logger` record of every activation: trigger source (`user` / `launch` / `app:zoom` / `deploy:jamf` / `schedule` / `mdm-forced`), duration, completion. IT pulls via `log show --predicate 'subsystem=="com.oldsalt.niacin"'`. Cheap given the unified-logging foundation already in place. (S)
- **Maintenance-window mode** — managed key `maintenanceWindow: { start, end, weekdays }` defining time slots where Niacin force-activates blind. Pairs with `forceActiveDuringDeploys` for the "stay awake during the deploy IF it falls inside the window" pattern. (M)
- **Wake-from-sleep for scheduled deploys** — register `pmset schedule wake` from a managed key so Niacin can wake the device for a deploy window. Coordinates with macOS Power Nap. (M)
- **"Safe to sleep" lock-screen badge** — when nothing is running and no maintenance window is active, surface a small lock-screen indicator. Inverts the model — IT teams know when machines are reclaim-ready. (L, optional)
- **Ship a sample `.mobileconfig`** alongside the example plists in the README, ready to upload to JAMF. (S)
- **Document signing & notarization for org deployment** — user-facing "for IT admins" section in the README; mostly already covered by `RELEASING.md` but the audience is different. (S)
- **Signed-release CI workflow** — tag-triggered job that lifts `scripts/release.sh` into a GitHub Action once the cert + notarytool API key can be loaded from secrets. Required secrets: `DEVELOPER_ID_P12` + `DEVELOPER_ID_P12_PASSWORD`, plus `APP_STORE_CONNECT_KEY_ID` / `ISSUER_ID` / `API_KEY`. (M)

### Stream 2 — AI workstation

Apple Silicon Macs are now a popular cheap entry into 64–192 GB unified-memory AI workstations (Mac mini orders are reportedly sold out for this reason). **None of the existing competitors address this at all.** The target user is someone running a 70B model overnight on an M-series mini and discovering at breakfast that macOS slept the box and killed the run.

- **AI-runtime auto-detect** ★ — process / port watchlist: Ollama (`:11434`), LM Studio (`:1234`), `llama.cpp` server, MLX server, ComfyUI, AUTOMATIC1111, InvokeAI, vLLM, TGI, OpenWebUI, Mistral.rs, Aphrodite, mlx-lm. Force-activate when any is loaded. Configurable allowlist; defaults shipped. (M)
- **Active-inference detection** — a step beyond "Ollama is running": poll the runtime's API (e.g. `:11434/api/ps`) or watch the port for active connections. Auto-deactivate when truly idle for N minutes, not just because the process is up. (M)
- **MCP server mode** ★ — expose Niacin as a Model Context Protocol server so Claude / Cursor / Aider / Continue.dev can call `niacin.keep_awake_for(minutes, reason)` before kicking off a long tool call. ~100 lines of Swift + the MCP SDK. Most timely and distinctive idea in the entire roadmap; nobody else has it. (M)
- **GPU / Neural Engine load trigger** — sample via `powermetrics --samplers gpu_power,ane_power` (or IOKit). Stay awake while ANE or GPU > threshold for sustained period. AI workloads hammer ANE/GPU specifically; faster signal than CPU. (M–L)
- **Memory-pressure trigger** — wired-pages > N GB or sustained memory pressure indicates an AI model is loaded. Faster signal than process detection. (M)
- **"AI workstation mode" preset** — one-click profile: indefinite activation, system-stays-awake but display-can-sleep, ignores lid close, "AI training in progress" tooltip. (S)
- **Cool-down after long workloads** — when an AI session ends, schedule N-min cool-down before allowing sleep so fans spin down before thermal pressure peaks during sleep. Status: "5m cool-down active before sleep allowed". (S)
- **Thermal observability** — surface in tooltip when CPU/GPU sustained > 90°C for 10+ min. Doesn't change behaviour, just informs. AI on fanless minis can quietly thermal-throttle. (S)
- **Notification when long jobs complete** — when a watched AI process exits, fire a UserNotification with sound. Overnight inference / fine-tune watchers see "Ollama has been idle for 5 min. Niacin can let the system sleep." (S)
- **Battery-protective AI mode** — refuse force-activation triggers when on battery + battery < 50%, with an explicit override. AI inference on battery is brutal; a guardrail for laptop AI users. (S)

### Stream 3 — Developer / power-user

Meet developers where they live: terminal, CI, automation. The competitor space hasn't shipped this well — Lungo has URL schemes, Amphetamine has triggers, but nobody has a coherent CLI + scripting story.

- **URL scheme handler** ★ — `niacin://activate?duration=1800&reason=zoom-call` / `niacin://deactivate`. Tiny effort, huge surface-area unlock — every other automation tool the user already owns (Calendar reminders, Shortcuts, Stream Deck, webhooks) instantly becomes a Niacin trigger. (S)
- **`niacin run -- <cmd>`** ★ — `niacin run --keep-awake -- bazel build //...` runs the command and force-activates while it executes; auto-deactivates on exit. Replaces dozens of `caffeinate -i ./long-job.sh` invocations with one that surfaces in the menu bar. (S)
- **`niacin` CLI** — full feature parity with the menu (`niacin status`, `niacin activate 30m`, `niacin deactivate`, `niacin watch <pid>`). Power-users automate it; CI runners can call it from scripts. Pairs with `niacin run`. (M)
- **Build-tool / container-runtime auto-detect** — auto-stay-awake while `xcodebuild`, `swift build`, `gradle daemon`, `docker buildx`, `webpack --watch`, `vite`, `cargo build`, `bazel`, `make`, Docker Desktop, OrbStack, or Colima with active containers are running. Configurable allowlist; defaults shipped. (M)
- **AppleScript dictionary** — expose `activate for X minutes` / `deactivate` as scriptable verbs. Pairs with URL scheme; same capability, different audience. (S)
- **Shortcuts.app actions** — first-class Intents for "Activate Niacin" / "Deactivate Niacin" / "Niacin status". (S–M)
- **Bind-to-PID** — drag a process from Activity Monitor onto the menu bar icon → "stay awake until this PID exits". Replicates `caffeinate -w PID` with UI. (M)
- **xbar / SwiftBar / Übersicht status export** — emit a JSON status file at `~/Library/Caches/com.oldsalt.niacin/status.json` so custom menu bar tools can render Niacin state inline with everything else they show. (S)
- **Charging-state trigger** — "Stay awake only while plugged in". Covers the laptop-on-couch case where battery isn't the right signal but mains-power is. (S)

### Cross-cutting features

Items that span streams or don't fit cleanly into one bucket.

- **Global hotkey to toggle** — quick activation without opening the menu (configurable, MDM-lockable). (S)
- **Custom user durations** — let users add their own preset alongside the defaults (still subject to `maxDurationSeconds`). (S)
- **Auto-deactivate on battery / low battery** — common request for laptop users; trivial via `IOPSCopyPowerSourcesInfo`. Pairs with the AI battery-protective mode. (S)
- **Schedule windows** — "always awake 09:00–17:00 on weekdays". Useful for kiosks, also MDM-controllable. Pairs with maintenance-window. (M)
- **Extend / snooze a running session** — add 15 min without deactivating first. (S)
- **Gentle countdown end** — 30-sec visible warning + optional sound before a timed session expires, instead of a hard cutoff. Removes the "wait, why did my screen lock during a 2-hour render?" surprise. (S)
- **Lid-close intent memory** — if you had an active session and closed the lid, offer one-click resume on re-open ("Resume your 1h 30m session?"). Inverts the usual lid-close-kills-everything pattern. (S)
- **Activity histogram / weekly stats** — "You kept your Mac awake 14h this week, mostly between 10:00 and 16:00." In-memory only, no tracking, no storage. Surprisingly engaging. (M)

---

## Polish & UX

- **First-launch onboarding sheet** — short explainer for non-IT users; suppressed when `activateOnLaunch` is managed
- **VoiceOver labels** on menu items and the menu bar icon — currently nothing read out for assistive tech
- **Settings window resizability / layout pass** — the fixed `width: 380, height: 340` is tight in German (longest current locale); once ja/zh-Hans land it'll need to flex
- **ja and zh-Hans translations** — deferred from the v1.2 localization push. Both deserve a native review and have layout/font implications (Japanese tends to run wider, Chinese narrower; Japanese has only an `other` plural form)
- **Native review of fr/de/es/it translations** — shipped from a fluent generalist, not a professional translator. Worth a sanity-pass before broad enterprise distribution. Most likely nitpicks: the menu-bar status fragments ("screen can sleep", "screen stays on") which sit awkwardly mid-sentence in some Romance constructions

---

## Code health

- **Crash log forwarding** — at minimum, document where `os.Logger` output lands so IT can collect it
- **Swift 6 strict-concurrency cleanup** — `PolicyWatcher.swift:31` warns that `self.onChange = onChange` loses the `@MainActor` annotation when crossing the `queue.async` boundary. Cosmetic warning today (build/notarize succeed) but will be a hard error when the project flips to Swift 6 language mode. Fix: annotate the `onChange` storage and the `start(onChange:)` parameter as `@Sendable @MainActor` so the types match exactly across the dispatch boundary.
- **Don't re-enable App Sandbox without a plan for Sparkle** — `ENABLE_APP_SANDBOX = NO` was set in v1.5 because sandboxed Sparkle can't acquire the admin rights needed to replace `/Applications/Niacin.app`. Re-enabling sandbox requires either restricting installs to `~/Applications` (UX hostile) or shipping an SMJobBless privileged helper (days of work). If a future App Store distribution is needed, that's a parallel build target, not a flip of this flag.
- **`RELEASING.md` polish** — the per-release runbook predates the Sparkle work; should be updated to (a) call out the niacin-web mirror step explicitly, (b) note the sandbox-off posture so it's not accidentally re-enabled in some future Xcode build-settings refactor, (c) add the `xattr -dr com.apple.quarantine` reminder for anyone testing local installs from `.zip`.

### Engine robustness (the core sleep mechanism)

The big-ticket items here shipped in v1.7: caffeinate replaced with direct IOKit `IOPMAssertion` calls, and the test gap on the engine is now closed with `SleepPreventerTests` (5 unit tests via `pmset -g assertions` introspection) plus `AppStateIntegrationTests` (6 tests covering the activate/deactivate/reloadPolicy glue). One item remains:

- **Detect-and-surface engine failure** — when `IOPMAssertionCreateWithName` returns non-success (rare, but possible under restrictive sandbox profiles or future macOS releases), Niacin currently logs the error but the user sees nothing — the menu briefly looks active and then resets. Surface it visibly: menu icon shows an error state, tooltip says "Niacin can't prevent sleep — check with IT", audit log records the specific `IOReturn` code. (S)
