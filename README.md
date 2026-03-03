# Claude Local Speech (STT + TTS + Whisper)

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
- Smart summaries — Claude generates spoken summaries, not raw text dumps
- Fallback mode — works even without the `[VOICE:]` tag (strips markdown, truncates)

## Requirements

- macOS with Apple Silicon (M1/M2/M3/M4)
- [uv](https://docs.astral.sh/uv/) package manager
- [Claude Code](https://claude.ai/claude-code) CLI or VS Code extension
- `jq` (install via `brew install jq`)

## Quick Start

```bash
# Clone
git clone https://github.com/PerIPan/Claude-Local-Speech-STT-TTS-Whisper.git
cd Claude-Local-Speech-STT-TTS-Whisper

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

### 2. Start the servers

```bash
./servers/start-servers.sh
```

This launches:
- **Port 8000** — Whisper STT (speech-to-text)
- **Port 8100** — Kokoro TTS (text-to-speech)

### 3. Configure Claude Code

Copy `CLAUDE.md` to your project root:

```bash
cp CLAUDE.md /path/to/your/project/
```

Add the hook to your project's `.claude/settings.json`:

```json
{
  "hooks": {
    "stop": [{
      "type": "command",
      "command": "/path/to/Claude-Local-Speech-STT-TTS-Whisper/hooks/tts-hook.sh"
    }]
  }
}
```

### 4. Speech Input (STT)

For speech-to-text input into Claude Code, you have three options:

**Option A: macOS Dictation (Recommended)**

Built into macOS, works in any text field including Claude Code's chat panel.

1. Go to **System Settings > Keyboard > Dictation** and enable it
2. Press **fn fn** (fn key twice) or the **microphone key** to start dictating
3. Speak your message, then press fn again or click Done

No extensions needed. Works everywhere on your Mac.

**Option B: macOS Voice Control**

For fully hands-free operation:

1. Go to **System Settings > Accessibility > Voice Control** and enable it
2. Say "click" to focus the input, dictate your message, then say "press return"

**Option C: [Voquill](https://github.com/nicobailey/Voquill) (Open Source)**

Voquill is an open-source macOS speech input app that works system-wide with your local Whisper server.

> **Note:** The VS Code Speech extension (`ms-vscode.vscode-speech`) does **not** work with Claude Code's chat panel, as it uses a custom UI component.

## Configuration

Environment variables to customize behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `TTS_URL` | `http://localhost:8100/v1/audio/speech` | TTS server endpoint |
| `TTS_VOICE` | `af_heart` | Kokoro voice name |
| `TTS_MODEL` | `prince-canuma/Kokoro-82M` | TTS model |
| `STT_PORT` | `8000` | Whisper server port |
| `WHISPER_MODEL` | `mlx-community/whisper-large-v3-turbo` | Whisper model |

## File Structure

```
Claude-Local-Speech-STT-TTS-Whisper/
├── CLAUDE.md                  # Voice tag instructions (copy to your project)
├── setup.sh                   # One-click installer
├── hooks/
│   └── tts-hook.sh           # Claude Code stop hook (async TTS)
├── servers/
│   ├── whisper_server.py     # OpenAI-compatible Whisper STT server
│   └── start-servers.sh      # Launch both servers
└── scripts/
    └── speak.sh              # Standalone TTS utility
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

## Credits

- [MLX Audio](https://github.com/Blaizzy/mlx-audio) — TTS and STT on Apple Silicon
- [MLX Whisper](https://github.com/ml-explore/mlx-examples) — Whisper on MLX
- [Kokoro](https://huggingface.co/prince-canuma/Kokoro-82M) — TTS model
- [Claude Code](https://claude.ai/claude-code) — Anthropic's CLI for Claude
- [Voquill](https://github.com/nicobailey/Voquill) — Open source speech input for macOS

## License

MIT
