# Hands-Free Mode — Implementation Plan

Companion to [hands-free-mode-design.md](./2026-03-10-hands-free-mode-design.md).

## Prerequisites

`HotkeyManager`, `DictationManager`, and `AudioRecorder` are compiled into the app binary but their source is not in the repo. These classes handle hotkey capture, recording lifecycle, and audio engine management. The plan below works within that constraint — extending behavior through the existing callback pattern rather than modifying those classes directly.

If source becomes available, steps marked **(source-only)** can be done more cleanly.

## Phase 1: Hold-to-Talk

**Goal:** Hold PTT key to record, release to submit. Minimal change, high value.

### Step 1.1 — Add interaction mode enum and persistence

- Create `InteractionMode` enum: `.pressToTalk`, `.holdToTalk`, `.handsFree`
- Add `Paths.interactionMode` file path (e.g., `~/Library/Application Support/ClaudeWhisperer/interaction_mode`)
- Read/write mode on app launch and settings change.

**Files:** `Paths.swift`

### Step 1.2 — Add mode selector to menubar

- Add a `Picker` in `MenuBarView.swift` within the Push-to-Talk section.
- Three options: "Press to Talk", "Hold to Talk", "Hands-Free".
- Persist selection via the file from Step 1.1.
- Publish mode to `AppDelegate` via environment or notification.

**Files:** `MenuBarView.swift`

### Step 1.3 — Wire key-up callback in AppDelegate

- `HotkeyManager` currently exposes `onKeyDown` and `onToggle`.
- For hold-to-talk, we need `onKeyUp` (or repurpose `onToggle` based on mode).
- **If source available (source-only):** add `onKeyUp` callback to `HotkeyManager`.
- **Without source:** `onToggle` fires on both press and release in toggle mode. We can track timing in `AppDelegate` — if the gap between two toggles is short and mode is hold-to-talk, treat the second toggle as "release → submit."
- On release in hold-to-talk mode: call `dictationManager.toggle()` to stop recording, then trigger transcription + submit.

**Files:** `AppDelegate.swift`

### Step 1.4 — Auto-submit on transcription complete

- Already implemented: `press_enter()` in `unified_server.py` fires when `auto_submit` flag exists.
- Verify hold-to-talk triggers the same transcription → submit flow.
- The Swift app's `DictationManager` posts audio to `/v1/audio/transcriptions` and pastes the result. The server's `press_enter()` then submits it.

**Files:** Verification only, no changes expected.

### Step 1.5 — Update overlay status text

- In `TranscriptionOverlay.swift`, update `statusText` to reflect mode:
  - Hold-to-talk recording: "Recording... release to submit"
  - Hold-to-talk idle: "Hold [key] to talk"

**Files:** `TranscriptionOverlay.swift`

---

## Phase 2: TTS Latency

**Goal:** Sub-one-second from response to first audio.

### Step 2.1 — Pre-warm Kokoro model

- On server startup, fire a dummy TTS request (empty or single-word) to load the model and pipeline into memory.
- This eliminates the "Fetching 63 files" and "Creating new KokoroPipeline" delay on first real request.

**Files:** `servers/unified_server.py` (add `@app.on_event("startup")` handler)

### Step 2.2 — Cache server health in TTS hook

- Currently `tts-hook.sh` curls `/models` on every invocation (~150ms).
- Write a timestamp file on successful health check. Skip the check if timestamp is less than 30 seconds old.

**Files:** `hooks/tts-hook.sh`

### Step 2.3 — Reduce hook shell overhead

- The hook spawns bash, loads jq, builds JSON, runs curl — ~300ms before the TTS request even fires.
- Alternative: add a `/v1/audio/speak` endpoint to `unified_server.py` that accepts text directly (no audio file upload) and returns audio. The hook becomes a single curl POST.
- Or: have the server itself watch for response completion and generate TTS proactively (eliminates the hook entirely for hands-free mode).

**Files:** `servers/unified_server.py`, `hooks/tts-hook.sh`

### Step 2.4 — Measure and validate

- Add timing logs at each stage (hook start, TTS request sent, audio received, playback started).
- Benchmark against the 1-second target.

**Files:** `hooks/tts-hook.sh`, `servers/unified_server.py`

---

## Phase 3: Hands-Free Mode

**Goal:** Continuous mic, silence-based submit, barge-in with "hold on."

### Step 3.1 — Continuous mic capture

- In hands-free mode, `AudioRecorder` should start on mode activation and stay running.
- **Without source:** We can toggle the recorder on via `dictationManager.toggle()` when entering hands-free mode, and keep it running across transcription cycles.
- **With source (source-only):** Add a `startContinuous()` method to `AudioRecorder` that captures without the stop-on-toggle behavior.

**Files:** `AppDelegate.swift` (or `AudioRecorder.swift` if source available)

### Step 3.2 — Silence detection

- Use `AudioRecorder.levelHistory` (already tracks audio energy for the waveform) to detect silence.
- Add a timer in `AppDelegate` or a new `HandsFreeController`:
  - Sample audio level every 100ms.
  - If level stays below threshold for 3 seconds, trigger transcription + submit.
  - Any spike above threshold resets the timer.
- Calibrate threshold: sample ambient level for 1 second when entering hands-free mode.

**Files:** New `HandsFreeController.swift` (or inline in `AppDelegate.swift`)

### Step 3.3 — Mic muting during TTS

- When TTS playback starts (detected via `tts_playing.lock` file, already polled in `TranscriptionOverlay`), pause mic capture.
- When TTS ends (lock file removed), resume mic capture.
- This prevents Whisper from transcribing the agent's voice.

**Files:** `AppDelegate.swift` or `HandsFreeController.swift`

### Step 3.4 — Barge-in keyword detection

- Use `SFSpeechRecognizer` (Apple Speech framework) for lightweight on-device keyword spotting.
- Only active during TTS playback (mic is otherwise muted, but keyword spotter listens on a separate tap).
- On detecting "hold on":
  1. Kill TTS playback (HTTP to server or direct `pkill afplay`).
  2. Remove `tts_playing.lock`.
  3. Unmute mic, transition to recording state.

**Implementation notes:**
- `SFSpeechRecognizer` works with `SFSpeechAudioBufferRecognitionRequest` for live audio.
- Set `shouldReportPartialResults = true` to detect "hold on" as soon as it's spoken.
- Requires Speech Recognition permission (add to Info.plist: `NSSpeechRecognitionUsageDescription`).

**Files:** New `KeywordSpotter.swift`, `Info.plist`

### Step 3.5 — PTT key as instant submit in hands-free

- In hands-free mode, tapping the PTT key should:
  1. Cancel the silence timer.
  2. Immediately stop recording and trigger transcription + submit.
- Same as press-to-talk "stop" behavior, just without needing a "start" press first (mic is already on).

**Files:** `AppDelegate.swift`

### Step 3.6 — Update overlay for hands-free

- New status states:
  - "Listening..." (idle, mic on, waiting for speech)
  - "Recording..." (speech detected, buffering)
  - "Submitting..." (silence detected or key tapped)
  - "Agent thinking..." (waiting for response, mic muted)
  - "Agent speaking..." (TTS playing, keyword spotter active)
- Show silence countdown in the last 1-2 seconds before auto-submit.

**Files:** `TranscriptionOverlay.swift`

### Step 3.7 — Mode selector wiring

- Connect the mode selector from Step 1.2 to the hands-free controller.
- On mode change:
  - `pressToTalk` → stop continuous mic, use toggle behavior.
  - `holdToTalk` → stop continuous mic, use hold behavior.
  - `handsFree` → start continuous mic, activate silence detection.
- Persist across app restart.

**Files:** `AppDelegate.swift`, `MenuBarView.swift`

---

## Phase 4: Polish and Edge Cases

### Step 4.1 — Graceful mode transitions

- Switching modes while recording: stop current recording, discard audio, enter new mode cleanly.
- Switching modes while TTS playing: let TTS finish, then enter new mode.

### Step 4.2 — Error recovery

- If server crashes during hands-free mode, detect via health check failure, show error in overlay, pause mic until server recovers.
- If keyword spotter fails to initialize (permission denied), fall back to key-only barge-in.

### Step 4.3 — Power and resource management

- Hands-free mode keeps mic and possibly Speech framework active continuously.
- Add auto-sleep: if no interaction for N minutes, pause mic and show "Paused" in overlay. Any keypress resumes.
- Monitor energy impact and optimize polling intervals.

### Step 4.4 — Testing

- Manual test matrix: each mode × each action (start, stop, submit, barge-in, mode switch).
- Edge cases: rapid mode switching, server restart during recording, very long silence, very short utterances.

---

## Dependency Graph

```
Phase 1 (Hold-to-Talk)
  1.1 → 1.2 → 1.3 → 1.4 → 1.5

Phase 2 (TTS Latency) — independent of Phase 1
  2.1 → 2.2 → 2.3 → 2.4

Phase 3 (Hands-Free) — depends on Phase 1
  1.5 → 3.1 → 3.2 → 3.3 → 3.4 → 3.5 → 3.6 → 3.7

Phase 4 (Polish) — depends on Phase 3
  3.7 → 4.1 → 4.2 → 4.3 → 4.4
```

Phases 1 and 2 can be worked on in parallel.

## Open Questions

1. **HotkeyManager source** — Is source available? Hold-to-talk is much cleaner with a real `onKeyUp` callback. Without it, we rely on timing heuristics.
2. **AudioRecorder source** — Continuous capture for hands-free ideally needs a mode where the recorder doesn't stop on toggle. Without source, we work around it.
3. **SFSpeechRecognizer resource usage** — Need to benchmark. If too heavy for continuous keyword spotting, fall back to energy-spike detection for barge-in.
4. **Silence threshold** — 3 seconds is the starting point. May need user-configurable setting after testing.
