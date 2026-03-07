#!/bin/bash
# Start STT + TTS servers for Claude Voice Mode
# Usage: ./start-servers.sh [venv_path]
#
# Voice input is separate: ./scripts/start-input-voice-whisper.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

VENV_PATH="${1:-$HOME/mlx-openai-whisper}"

if [ ! -f "$VENV_PATH/bin/activate" ]; then
  echo "Error: Virtual environment not found at $VENV_PATH"
  echo "Usage: $0 [path/to/venv]"
  exit 1
fi

source "$VENV_PATH/bin/activate"

STT_PORT="${STT_PORT:-8000}"
TTS_PORT="${TTS_PORT:-8100}"

echo "Starting Whisper STT on http://localhost:$STT_PORT"
python "$SCRIPT_DIR/whisper_server.py" &
STT_PID=$!

echo "Starting TTS on http://localhost:$TTS_PORT"
python -m mlx_audio.server --host 127.0.0.1 --port "$TTS_PORT" &
TTS_PID=$!

# Wait for servers to be ready
echo "Waiting for Whisper server..."
STT_READY=false
for i in $(seq 1 30); do
  curl -s "http://localhost:$STT_PORT/models" > /dev/null 2>&1 && { STT_READY=true; break; }
  sleep 1
done
$STT_READY || echo "WARNING: Whisper server did not start within 30s"

echo "Waiting for TTS server..."
TTS_READY=false
for i in $(seq 1 60); do
  curl -s "http://localhost:$TTS_PORT/v1/models" > /dev/null 2>&1 && { TTS_READY=true; break; }
  sleep 1
done
$TTS_READY || echo "WARNING: TTS server did not start within 60s"

echo ""
if $STT_READY && $TTS_READY; then
  echo "Servers ready. For voice input, run in another terminal:"
else
  echo "Some servers may not be ready. For voice input, run in another terminal:"
fi
echo "  ./scripts/start-input-voice-whisper.sh"
echo ""
echo "Press Ctrl+C to stop servers."

cleanup() {
  echo "Shutting down..."
  kill "$STT_PID" "$TTS_PID" 2>/dev/null
  rm -f "$HOME/Library/Application Support/ClaudeWhisperer/tts_playing.lock" "$HOME/Library/Application Support/ClaudeWhisperer/tts_hook.pid"
  wait 2>/dev/null
  echo "Done."
  exit 0
}
trap cleanup INT TERM
wait
