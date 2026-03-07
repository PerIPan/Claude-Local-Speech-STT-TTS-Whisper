"""Lightweight OpenAI-compatible Whisper STT server using MLX."""

import asyncio
import logging
import re
import signal
import subprocess
import threading
import mlx_whisper
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse, PlainTextResponse
from fastapi.middleware.cors import CORSMiddleware
import tempfile, os, uvicorn
from concurrent.futures import ThreadPoolExecutor

logger = logging.getLogger("whisper_server")

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:8000", "http://localhost:8100", "http://127.0.0.1:8000", "http://127.0.0.1:8100"],
    allow_methods=["POST", "GET"],
    allow_headers=["Content-Type"],
)

MODEL = os.getenv("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")

# Auto-submit: flag file toggled by the menubar app
AUTO_SUBMIT_FLAG = os.path.expanduser(
    "~/Library/Application Support/ClaudeWhisperer/auto_submit"
)
AUTO_FOCUS_APP = os.path.expanduser(
    "~/Library/Application Support/ClaudeWhisperer/auto_focus_app"
)
SUBMIT_TRIGGERS = ["submit", "send it", "go ahead", "send", "enter"]

# Sort triggers longest-first so multi-word triggers match before substrings
SUBMIT_TRIGGERS.sort(key=len, reverse=True)

_transcribe_lock = threading.Lock()
# Dedicated single-thread executor for transcription to avoid starving the default pool
_transcribe_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="transcribe")

# Max upload size: 100MB
MAX_UPLOAD_BYTES = 100 * 1024 * 1024

# TTS PID/lock files in per-user app support dir instead of /tmp
_APP_SUPPORT = os.path.expanduser("~/Library/Application Support/ClaudeWhisperer")
TTS_PIDFILE = os.path.join(_APP_SUPPORT, "tts_hook.pid")
TTS_LOCKFILE = os.path.join(_APP_SUPPORT, "tts_playing.lock")

# Allowed apps for auto-focus (prevent AppleScript injection)
_ALLOWED_FOCUS_APPS = {
    "Code", "Code - Insiders", "Cursor", "Windsurf",
    "Terminal", "iTerm2", "Warp", "Alacritty", "Ghostty",
}

models_response = {
    "object": "list",
    "data": [{"id": "whisper-1", "object": "model", "owned_by": "local"}]
}

@app.get("/v1/models")
@app.get("/models")
async def list_models():
    return models_response

def _serialize_transcribe(tmp_path, language):
    """Run transcription with mutex to prevent concurrent MLX access."""
    with _transcribe_lock:
        return mlx_whisper.transcribe(tmp_path, path_or_hf_repo=MODEL, language=language)


def check_submit_trigger(text):
    """Check if text ends with a submit trigger. Returns (cleaned_text, should_submit)."""
    lower = text.lower().rstrip(" .,!?")
    for trigger in SUBMIT_TRIGGERS:
        if lower.endswith(trigger):
            # Use word boundary only for single-word triggers
            if " " in trigger:
                pattern = r'\s*' + re.escape(trigger) + r'[.!?,]?$'
            else:
                pattern = r'\s*\b' + re.escape(trigger) + r'[.!?,]?$'
            cleaned = re.sub(pattern, '', text.strip(), flags=re.IGNORECASE)
            return cleaned, True
    return text, False


def focus_target_app():
    """Bring the target app to front if auto-focus is configured."""
    try:
        if not os.path.exists(AUTO_FOCUS_APP):
            return
        with open(AUTO_FOCUS_APP) as f:
            app_name = f.read().strip()
        if not app_name:
            return
        # Validate against allowlist to prevent AppleScript injection
        if app_name not in _ALLOWED_FOCUS_APPS:
            # Also allow names that are pure alphanumeric + spaces (no quotes/special chars)
            if not re.match(r'^[A-Za-z0-9 ._-]+$', app_name):
                logger.warning("Blocked suspicious auto-focus app name: %r", app_name)
                return
        subprocess.Popen(
            ["osascript", "-e", f'tell application "{app_name}" to activate'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        logger.exception("focus_target_app failed")


def kill_tts():
    """Kill any running TTS playback (barge-in)."""
    try:
        # Read PID and validate before killing
        try:
            with open(TTS_PIDFILE) as f:
                pid_str = f.read().strip()
            pid = int(pid_str)
            if pid > 0:
                # Verify it's actually an afplay or tts_hook process before killing
                try:
                    result = subprocess.run(
                        ["ps", "-p", str(pid), "-o", "comm="],
                        capture_output=True, text=True, timeout=2
                    )
                    comm = result.stdout.strip()
                    if comm and ("afplay" in comm or "tts" in comm or "bash" in comm):
                        os.kill(pid, signal.SIGTERM)
                except (subprocess.TimeoutExpired, ProcessLookupError, PermissionError):
                    pass
        except (FileNotFoundError, ValueError):
            pass

        # Also kill afplay spawned by this user's hook
        subprocess.run(["pkill", "-f", "afplay.*tts_"], capture_output=True, timeout=2)

        # Clean up files
        for path in (TTS_PIDFILE, TTS_LOCKFILE):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
    except Exception:
        logger.exception("kill_tts failed")


def press_cmd_enter():
    """Press Cmd+Enter in the frontmost app via AppleScript."""
    try:
        subprocess.Popen(
            ["osascript", "-e", 'tell application "System Events" to key code 36 using command down'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        logger.exception("press_cmd_enter failed")


async def do_transcribe(file, model, language, response_format):
    tmp_path = None
    try:
        # Read with size limit
        data = await file.read()
        if len(data) > MAX_UPLOAD_BYTES:
            return JSONResponse({"error": "File too large (max 100MB)"}, status_code=413)

        # Preserve original file extension for correct decoder selection
        ext = ".wav"
        if file.filename:
            _, file_ext = os.path.splitext(file.filename)
            if file_ext:
                ext = file_ext

        with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
            tmp.write(data)
            tmp_path = tmp.name

        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(
            _transcribe_executor,
            lambda p=tmp_path, l=language: _serialize_transcribe(p, l or None)
        )
        text = result.get("text", "")
    except Exception:
        logger.exception("Transcription failed")
        return JSONResponse({"error": "Transcription failed"}, status_code=500)
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except FileNotFoundError:
                pass

    # Run post-processing in executor to avoid blocking event loop
    loop = asyncio.get_running_loop()

    # Auto-focus: bring target app to front before Voquill types
    await loop.run_in_executor(None, focus_target_app)

    # Auto-submit: check trigger words if enabled
    should_submit = False
    if os.path.exists(AUTO_SUBMIT_FLAG):
        text, should_submit = check_submit_trigger(text)

    # Barge-in + submit: kill TTS and press Cmd+Enter
    if should_submit:
        await loop.run_in_executor(None, kill_tts)
        _submit_task = asyncio.create_task(_delayed_enter())

    if response_format == "text":
        return PlainTextResponse(text)
    return JSONResponse({"text": text})


async def _delayed_enter():
    """Wait briefly for Voquill to finish typing, then press Cmd+Enter."""
    await asyncio.sleep(0.3)
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, press_cmd_enter)


@app.post("/v1/audio/transcriptions")
@app.post("/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(default="whisper-1"),
    language: str = Form(default=None),
    response_format: str = Form(default="json"),
):
    return await do_transcribe(file, model, language, response_format)

if __name__ == "__main__":
    port = int(os.getenv("STT_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port)
