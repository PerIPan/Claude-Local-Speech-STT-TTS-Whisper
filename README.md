# Claude Whisperer

Voice mode for [Claude Code](https://claude.ai/claude-code) on Apple Silicon. Talk to Claude, hear Claude talk back — all running locally on your Mac.

## How It Works

```
You speak -> Whisper (STT) -> Claude Code -> [VOICE: tag] -> Kokoro (TTS) -> You hear
```

1. **You speak** — transcribed locally by Whisper on Apple Silicon via MLX
2. **Claude responds** — full detailed text on screen as usual
3. **Claude adds a `[VOICE: ...]` tag** — a short conversational summary
4. **The hook extracts it** — sends only the spoken summary to Kokoro TTS
5. **You hear the response** — natural speech, fully async, interruptible

## Features

- 100% local — no cloud APIs, no data leaves your Mac
- Async playback — keep working while Claude speaks
- Interruptible — new responses cut off old audio
- Barge-in — press SPACE or just start speaking to interrupt TTS instantly
- Smart summaries — Claude generates spoken summaries, not raw text dumps
- Fallback mode — works even without the `[VOICE:]` tag (strips markdown, truncates)
- Auto mic pause — mic stops during TTS playback, resumes after (no feedback loops)
- Noise calibration — threshold adapts to your room at startup
- Click filtering — ignores keyboard clicks, only triggers on sustained speech
- Voice triggers — say "submit" to press Enter hands-free
- App targeting — only types into Terminal, VS Code, iTerm2, Warp
- Fast-fail — if TTS server is down, mic resumes immediately (no 30s block)

## Requirements

- macOS with Apple Silicon (M1/M2/M3/M4)
- [uv](https://docs.astral.sh/uv/) package manager
- [Claude Code](https://claude.ai/claude-code) CLI or VS Code extension
- `jq` (install via `brew install jq`)

## Quick Start

```bash
# Clone
git clone https://github.com/PerIPan/Claude-Whisperer.git
cd Claude-Whisperer

# Install (creates venv, downloads models)
chmod +x setup.sh
./setup.sh

# Start servers
./servers/start-servers.sh
```

## Setup

### 1. Run the setup script

```bash
./setup.sh                          # default venv: ~/mlx-openai-whisper
./setup.sh /path/to/custom/venv     # custom location
```

This installs all MLX dependencies including Whisper, Kokoro TTS, and spaCy.

**Python dependencies** (installed automatically by `setup.sh`):
`mlx-audio`, `mlx-whisper`, `sounddevice`, `numpy`, `requests`, `soundfile`, `spacy` (en_core_web_sm), `setuptools`

### 2. Start the servers

```bash
./servers/start-servers.sh
```

This launches:
- **Port 8000** — Whisper STT (speech-to-text) — OpenAI-compatible API
- **Port 8100** — Kokoro TTS (text-to-speech) — OpenAI-compatible API

### 3. Configure Claude Code

Copy `CLAUDE.md` to your project root:

```bash
cp CLAUDE.md /path/to/your/project/
```

Add the hook to your `.claude/settings.json` (global or project):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/Claude-Whisperer/hooks/tts-hook.sh",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

> Replace `/path/to/Claude-Whisperer` with the absolute path where you cloned the repo.

### 4. Speech Input (STT)

Choose one of the three options below for getting your voice into Claude Code.

**Option A: [Voquill](https://github.com/nicobailey/Voquill) + Local Whisper (Recommended — best accuracy)**

[Voquill](https://github.com/nicobailey/Voquill) is an open-source macOS speech input app that works system-wide. It supports **OpenAI-compatible API** endpoints, which means it connects directly to your local Whisper server — giving you Voquill's polished dictation UX with Whisper large-v3-turbo's superior accuracy.

**Why this combo is best:**
- **Whisper large-v3-turbo via MLX** — far more accurate than macOS dictation for code, technical jargon, abbreviations, and non-English words
- **Voquill UX** — global hotkey, system-wide input, clean text insertion into any app
- **No cloud dependency** — everything stays on your Mac
- **Glossary support** — add recurring technical terms to Voquill's dictionary for even better accuracy

**Setup:**

1. Install [Voquill](https://github.com/nicobailey/Voquill) (download from GitHub releases)
2. Make sure the Whisper server is running (`./servers/start-servers.sh`)
3. Open Voquill Settings → **Transcription**
4. Set mode to **OpenAI Compatible API**
5. Set the endpoint/base URL to your local Whisper server:
   ```
   http://localhost:8000/v1
   ```
6. Model: `whisper-1` (this is an alias — the server routes it to whatever Whisper model it loaded, default: large-v3-turbo)
7. API key: enter any dummy value (e.g. `sk-local`) — the local server doesn't validate it
8. Language: set to `en` (or your preferred language) for better accuracy

**Verify it works:** After configuring, speak into Voquill — it should transcribe via your local Whisper server. You should see `POST /v1/audio/transcriptions` log output in the server terminal.

**Pro tip:** Add your project-specific terms (API names, libraries, variable names) to Voquill's glossary/dictionary for best results with technical vocabulary.

**Option B: Whisper Voice Input Script (Hands-free, auto-submit)**

Uses your local Whisper server directly. Best for fully hands-free operation — auto-detects speech, transcribes, types into VS Code, and can auto-submit. No hotkey needed. Includes barge-in support (see below).

```bash
# Start voice input (keeps listening, types text into VS Code)
./scripts/start-input-voice-whisper.sh

# Or run directly with options:
python scripts/voice-input.py --loop                    # continuous listening
python scripts/voice-input.py --loop --submit           # always auto-press Enter
python scripts/voice-input.py --loop --silence 2.5      # adjust silence detection
python scripts/voice-input.py --loop --target Terminal   # target a different app
python scripts/voice-input.py --loop --hold              # hold-to-talk mode (Enter to start/stop)
```

Auto-pauses mic during TTS playback (no feedback loops), calibrates to room noise at startup. See [Voice Commands](#voice-commands) and [Barge-in](#barge-in) below.

> Requires Accessibility permission (System Settings → Privacy & Security → Accessibility). One-time setup.
> Only types into allowed apps (Terminal, VS Code, iTerm2, Warp) — won't send text to wrong windows.

**Option C: macOS Dictation (Zero setup fallback)**

Press **fn fn** (fn key twice) to dictate. Works instantly, no extra scripts needed. Text appears in the Claude Code input field — review it, then press Enter.

> **Note:** macOS dictation is less accurate for code/technical terms compared to Whisper. The VS Code Speech extension (`ms-vscode.vscode-speech`) does **not** work with Claude Code's chat panel, as it uses a custom UI component.

## Barge-in

When using the voice input script (Option B), you can interrupt Claude's TTS playback at any time — no need to wait for it to finish.

**Two ways to barge in:**

| Method | How | When |
|--------|-----|------|
| **Spacebar** | Press SPACE in the voice-input terminal | Any time TTS is playing |
| **Voice** | Just start speaking | Mic detects your voice above the TTS threshold |

**What happens:**
1. TTS audio stops immediately (afplay is killed)
2. Terminal bell sounds as confirmation
3. Mic resumes with a short 0.5s cooldown (vs. normal 1.5s)
4. You can start speaking your next request right away

**Voice barge-in** uses a higher energy threshold than normal speech detection (8x noise floor vs. 4x) to avoid the TTS speaker audio triggering it. For best results:
- Speak clearly and at a normal volume
- If your speakers are very loud, voice barge-in may trigger from TTS output — use headphones or press SPACE instead
- The spacebar method always works regardless of speaker volume

> **Note:** Spacebar barge-in is not available in `--hold` mode (conflicts with Enter-based recording). Voice barge-in works in all modes.

## Voice Commands

When using the Whisper voice input script (Option B), you can say these trigger words **at the end of your sentence** to auto-press Enter and submit to Claude:

| Voice Command | Example |
|---------------|---------|
| **"submit"** | "Fix the login bug, submit" |
| **"send"** | "Add error handling to the API, send" |
| **"send it"** | "Refactor this function, send it" |
| **"enter"** | "Run the tests, enter" |
| **"go ahead"** | "Deploy to staging, go ahead" |

The trigger word is stripped from the text before typing — Claude only sees your actual request. Trailing punctuation is also handled ("submit." works the same as "submit").

**Submit-only mode:** Say just the trigger word by itself (e.g. just "submit") to press Enter without typing anything — useful for submitting text you've already typed or reviewed.

**Always-submit mode:** Use `--submit` flag to auto-press Enter after every transcription without needing a trigger word:

```bash
python scripts/voice-input.py --loop --submit
```

> **Note:** Voice commands only work with Option B (Whisper voice input script). With Voquill (Option A) or macOS Dictation (Option C), review your text on screen and press Enter manually.

## Configuration

### TTS Hook (tts-hook.sh)

| Variable | Default | Description |
|----------|---------|-------------|
| `TTS_URL` | `http://localhost:8100/v1/audio/speech` | TTS server endpoint |
| `TTS_VOICE` | `af_heart` | Kokoro voice name |
| `TTS_MODEL` | `prince-canuma/Kokoro-82M` | TTS model |

### Whisper Server (whisper_server.py)

| Variable | Default | Description |
|----------|---------|-------------|
| `STT_PORT` | `8000` | Whisper server port |
| `WHISPER_MODEL` | `mlx-community/whisper-large-v3-turbo` | Whisper model |

### Voice Input (voice-input.py)

| Variable | Default | Description |
|----------|---------|-------------|
| `STT_URL` | `http://localhost:8000/v1/audio/transcriptions` | Whisper STT endpoint |
| `VOICE_TARGET` | `Code` | Target app for typing (e.g. `Terminal`, `iTerm2`) |

## File Structure

```
Claude-Whisperer/
├── CLAUDE.md                  # Voice tag instructions (copy to your project)
├── setup.sh                   # One-click installer
├── hooks/
│   └── tts-hook.sh           # Claude Code stop hook (async TTS)
├── servers/
│   ├── whisper_server.py     # OpenAI-compatible Whisper STT server
│   └── start-servers.sh      # Launch STT + TTS servers
└── scripts/
    ├── speak.sh                       # Standalone TTS utility
    ├── start-input-voice-whisper.sh   # Start voice input (run in separate terminal)
    └── voice-input.py                 # Whisper-powered voice input bridge
```

## How the VOICE Tag Works

Claude includes a `[VOICE: ...]` tag at the end of every response:

```
Here's the full technical explanation with code...

[VOICE: I fixed the authentication bug. It was a missing token refresh in the middleware.]
```

- You **see** the full response on screen
- You **hear** only the conversational summary
- No extra LLM needed — Claude generates the summary itself

## Troubleshooting

**No audio output:**
- Check TTS server is running: `curl http://localhost:8100/models`
- Check `jq` is installed: `which jq`
- Test manually: `echo "hello" | ./scripts/speak.sh`

**422 error from TTS:**
- Make sure `model` field is included in requests
- Install spaCy model: see setup.sh

**Very short audio (millisecond):**
- The hook might be matching a literal `[VOICE: ...]` mention in text
- This is handled by using `tail -1` to grab the last match

**Voquill not transcribing via local Whisper:**
- Check the Whisper server is running: `curl http://localhost:8000/v1/models`
- Verify Voquill's transcription mode is set to **OpenAI Compatible API**
- Verify endpoint is `http://localhost:8000/v1`
- Model should be `whisper-1`
- API key can be any non-empty string (e.g. `sk-local`)

**Voice input "osascript not allowed" error:**
- The voice input script uses AppleScript to type into the active app
- Grant **Accessibility** access: **System Settings → Privacy & Security → Accessibility**
- Toggle on **Terminal** and/or **Visual Studio Code** (whichever runs the script)
- This is a one-time macOS permission — required for any app to send keystrokes

**Voice input picks up TTS audio (feedback loop):**
- Auto-pause is built in — the mic automatically pauses while TTS is playing
- Use barge-in (SPACE or just speak) to interrupt TTS and resume mic immediately
- If voice barge-in triggers too easily from TTS speaker output, use headphones or lower speaker volume
- Default is type-only (no Enter) — review text before pressing Enter yourself

**Terminal stuck after crash (no echo, weird input):**
- If voice-input.py crashes or is killed with `kill -9`, the terminal may be in cbreak mode
- Run `reset` or `stty sane` to restore normal terminal behavior

## Credits

- [MLX Audio](https://github.com/Blaizzy/mlx-audio) — TTS and STT on Apple Silicon
- [MLX Whisper](https://github.com/ml-explore/mlx-examples) — Whisper on MLX
- [Kokoro](https://huggingface.co/prince-canuma/Kokoro-82M) — TTS model
- [Claude Code](https://claude.ai/claude-code) — Anthropic's CLI for Claude
- [Voquill](https://github.com/nicobailey/Voquill) — Open source speech input for macOS

## License

MIT
