# Hands-Free Mode Design

## Goal

Add hands-free voice interaction to Claude Whisperer so users can have a conversation with the agent without pressing buttons. Also add hold-to-talk as a lighter-weight alternative. Improve TTS latency to sub-one-second.

## Interaction Modes

Three modes, selectable from the menubar:

### 1. Press-to-talk (existing)

Press PTT key to start recording, press again to stop. Transcribes and auto-submits.

### 2. Hold-to-talk (new)

Hold PTT key to record. Release to stop, transcribe, and auto-submit. Feels immediate — no second keypress needed.

### 3. Hands-free (new)

Mic listens continuously. No buttons required for normal conversation flow.

**End of turn:**
- 3 seconds of silence triggers transcription and submit.
- Tapping the PTT key submits instantly (skip the silence wait).

**During agent TTS playback:**
- Mic is muted to prevent echo/feedback.
- Lightweight keyword detection stays active, listening for "hold on."

**Barge-in:**
- Say "hold on" while the agent is speaking.
- TTS stops immediately, mic unmutes, starts capturing new input.
- The interrupted response remains visible on screen.

## Architecture

Hybrid approach — Swift handles real-time audio, Python handles heavy ML.

### Swift app responsibilities

- Mic capture and audio buffering (all modes).
- Mode state machine: idle, recording, waiting-for-silence, playing-tts.
- Silence detection using audio energy levels (3-second threshold).
- Keyword spotting during TTS playback via Apple Speech framework ("hold on").
- Hold-to-talk: detect key-down/key-up events (not just toggles).
- Send buffered audio to Python server for transcription.
- UI: mode selector in menubar, overlay updates per mode.

### Python server responsibilities

- Whisper transcription (unchanged).
- Kokoro TTS (unchanged).
- Auto-submit: press Enter after transcription (already implemented).
- Kill TTS on barge-in signal from Swift app (existing `kill_tts`).

### Communication

- Swift → Python: HTTP POST `/v1/audio/transcriptions` (existing).
- Swift → Python: signal to kill TTS (new — could be HTTP endpoint or direct `pkill`).
- Python → Swift: transcription result in JSON response (existing).

## PTT Key

Same configurable key (Control, Option, Cmd, Fn) across all three modes. Already configurable in the app. Behavior changes based on selected mode:

| Mode | Key down | Key up | Silence (3s) |
|------|----------|--------|--------------|
| Press-to-talk | Toggle recording | Toggle recording | — |
| Hold-to-talk | Start recording | Stop + submit | — |
| Hands-free | Instant submit | — | Auto-submit |

## TTS Latency

Target: sub-one-second from response to first audio.

Current breakdown (~1.5-2s):
- Hook startup (bash, jq, curl health check): ~300ms
- TTS generation (Kokoro): ~1000ms
- Sequencing overhead: ~200ms

Optimizations:
1. **Pre-warm Kokoro model** — generate a silent/dummy request on server start so the model and pipeline are loaded before the first real request.
2. **Skip health check in hook** — cache server status; if confirmed alive within last 30s, skip the curl check to `/models`.
3. **Reduce hook startup** — consider moving TTS request logic from bash into the Python server (eliminate shell/jq/curl overhead entirely).

Stretch goal: streaming TTS (start playback while still generating) — depends on mlx_audio support.

## Barge-in: Keyword Detection

Use Apple's Speech framework (`SFSpeechRecognizer`) for lightweight, on-device keyword spotting.

- Only active during TTS playback.
- Listens for the phrase "hold on."
- On detection: send kill signal to TTS, transition to recording state.
- Low resource usage — no Whisper inference needed, runs on Apple's built-in speech engine.

Alternative if Speech framework is too heavy: use audio energy spike detection as a simpler barge-in trigger (any loud input during TTS = interrupt). Less precise but near-zero cost.

## Silence Detection

Use RMS (root mean square) energy of audio buffer frames.

- Threshold calibrated against ambient noise level (sample on mode activation).
- Timer starts when energy drops below threshold.
- After 3 seconds of continuous silence, trigger transcription and submit.
- Any speech resets the timer.
- PTT key tap bypasses the timer for instant submit.

## State Machine

```
                    ┌─────────────────────────┐
                    │         IDLE             │
                    │  (mic on in hands-free)  │
                    └──────┬──────────────────┘
                           │ voice detected / key press
                           v
                    ┌─────────────────────────┐
                    │       RECORDING          │
                    │  (buffering audio)       │
                    └──────┬──────────────────┘
                           │ silence 3s / key tap / key release
                           v
                    ┌─────────────────────────┐
                    │     TRANSCRIBING         │
                    │  (Whisper processing)    │
                    └──────┬──────────────────┘
                           │ text submitted
                           v
                    ┌─────────────────────────┐
                    │    WAITING FOR AGENT     │
                    │  (mic muted)             │
                    └──────┬──────────────────┘
                           │ TTS starts
                           v
                    ┌─────────────────────────┐
                    │     PLAYING TTS          │
                    │  (keyword spotting on)   │
                    └──────┬──────────────────┘
                           │ TTS ends / "hold on" detected
                           v
                        back to IDLE
```

## Out of Scope (v1)

- Full echo cancellation (mic open during TTS without keyword gating).
- Automatic silence threshold tuning.
- Multiple keyword phrases.
- Streaming TTS playback (stretch goal, depends on mlx_audio).
- Wake word to activate hands-free from sleep.

## Success Criteria

- Hold-to-talk works reliably: hold key, speak, release, text appears and submits.
- Hands-free works for a multi-turn conversation: speak, wait 3s or tap key, agent responds via TTS, speak again.
- Saying "hold on" during TTS stops playback and starts listening.
- TTS latency under 1 second for typical VOICE tag content.
- No echo: agent's TTS output is not transcribed as user input.
