#!/bin/bash
# Setup script for Claude Voice Mode
# Creates a uv venv with all dependencies for STT + TTS on Apple Silicon

set -e

VENV_PATH="${1:-$HOME/mlx-openai-whisper}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Claude Voice Mode Setup ==="
echo ""

# Check for Apple Silicon
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Warning: This setup is optimized for Apple Silicon (M-series) Macs."
  echo "MLX may not work on your architecture."
  read -p "Continue anyway? (y/n) " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check for uv
if ! command -v uv &> /dev/null; then
  echo "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  source "$HOME/.local/bin/env" 2>/dev/null || true
fi

# Create venv
echo "Creating virtual environment at $VENV_PATH..."
uv venv "$VENV_PATH" --python 3.13

source "$VENV_PATH/bin/activate"

# Install dependencies
echo "Installing mlx_audio (TTS + STT)..."
uv pip install mlx-audio

echo "Installing mlx_whisper..."
uv pip install mlx-whisper

echo "Installing spaCy English model (required by Kokoro TTS)..."
uv pip install en_core_web_sm@https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl

echo "Installing setuptools (required by webrtcvad)..."
uv pip install "setuptools<81"

# Make scripts executable
chmod +x "$SCRIPT_DIR/hooks/tts-hook.sh"
chmod +x "$SCRIPT_DIR/servers/start-servers.sh"
chmod +x "$SCRIPT_DIR/scripts/speak.sh"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "1. Start servers:  ./servers/start-servers.sh $VENV_PATH"
echo "2. Copy CLAUDE.md to your project root"
echo "3. Configure the hook in your project's .claude/settings.json:"
echo ""
echo '   {'
echo '     "hooks": {'
echo '       "stop": [{'
echo '         "type": "command",'
echo "         \"command\": \"$SCRIPT_DIR/hooks/tts-hook.sh\""
echo '       }]'
echo '     }'
echo '   }'
echo ""
echo "4. Enable macOS Dictation for voice input:"
echo "   System Settings > Keyboard > Dictation > Enable"
echo "   Press fn fn (fn key twice) to start dictating into Claude Code"
echo ""
echo "5. (Optional) Test TTS:  echo 'Hello world' | ./scripts/speak.sh"
