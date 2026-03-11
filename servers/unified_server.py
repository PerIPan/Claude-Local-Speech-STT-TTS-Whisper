"""Unified MLX Audio server — TTS + STT with auto-submit, auto-focus, barge-in."""

import asyncio
import ctypes
import ctypes.util
import logging
import os
import re
import signal
import subprocess
import io
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import soundfile as sf

import mlx_whisper
import uvicorn
from fastapi import File, Form, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse

# Import the mlx_audio server app (includes TTS + /v1/models + WebSocket STT)
from mlx_audio.server import app, model_provider, setup_cors, SpeechRequest

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("unified_server")

# NOTE: Voice cache fix applied directly in venv kokoro.py —
# commented out `pipeline.voices = {}` to prevent re-loading voice
# tensors from disk on every TTS request (~200-500ms saving).

# ---------------------------------------------------------------------------
# Remove mlx_audio's built-in /v1/audio/transcriptions so we can replace it
# with our version that adds auto-submit, barge-in, etc.
# ---------------------------------------------------------------------------
_original_count = len(app.routes)
_override_paths = {"/v1/audio/transcriptions", "/v1/models", "/v1/audio/speech"}
app.routes[:] = [
    r for r in app.routes
    if not (hasattr(r, "path") and r.path in _override_paths
            and hasattr(r, "methods")
            and (("POST" in (r.methods or set()) and r.path == "/v1/audio/transcriptions")
                 or ("GET" in (r.methods or set()) and r.path == "/v1/models")
                 or ("POST" in (r.methods or set()) and r.path == "/v1/audio/speech")))
]
_removed = _original_count - len(app.routes)
if _removed == 0:
    logger.warning(
        "Could not find mlx_audio routes to override. "
        "The mlx_audio library may have changed its route structure."
    )

# Reconfigure CORS for localhost
setup_cors(app, [
    "http://localhost:8000", "http://127.0.0.1:8000",
    "http://localhost:3000", "http://127.0.0.1:3000",
])

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
TTS_MODEL = os.getenv("TTS_MODEL", "prince-canuma/Kokoro-82M")
MAX_UPLOAD_BYTES = 100 * 1024 * 1024  # 100MB

_APP_SUPPORT = os.path.expanduser("~/Library/Application Support/OpenWhisperer")
AUTO_SUBMIT_FLAG = os.path.join(_APP_SUPPORT, "auto_submit")
AUTO_FOCUS_APP = os.path.join(_APP_SUPPORT, "auto_focus_app")
STT_LANGUAGE_FILE = os.path.join(_APP_SUPPORT, "stt_language")
TTS_PIDFILE = os.path.join(_APP_SUPPORT, "tts_hook.pid")
TTS_LOCKFILE = os.path.join(_APP_SUPPORT, "tts_playing.lock")

SUBMIT_TRIGGERS = sorted(
    ["submit", "send it", "go ahead", "send", "enter"],
    key=len, reverse=True,
)

# Pre-compiled regex patterns for submit triggers (avoid per-request compilation)
_SUBMIT_PATTERNS = {
    trigger: re.compile(
        (r'\s*' + re.escape(trigger) + r'[.!?,…]*$') if ' ' in trigger
        else (r'\s*\b' + re.escape(trigger) + r'[.!?,…]*$'),
        re.IGNORECASE
    )
    for trigger in SUBMIT_TRIGGERS
}

_ALLOWED_FOCUS_APPS = {
    "Code", "Code - Insiders", "Cursor", "Windsurf", "Zed", "Xcode",
    "Sublime Text", "Nova", "Fleet", "Claude",
    "Terminal", "iTerm2", "Warp", "Alacritty", "Ghostty",
}

# Global MLX GPU lock — serializes Metal operations (TTS + STT) to prevent
# concurrent GPU access which causes Metal assertion crashes.
# STT acquires with a 30s timeout so barge-in never deadlocks.
_mlx_gpu_lock = threading.Lock()
_transcribe_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="transcribe")
_tts_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tts")
_pending_enter_task: asyncio.Task | None = None
_enter_lock = asyncio.Lock()

# ---------------------------------------------------------------------------
# STT helpers (auto-submit, auto-focus, barge-in)
# ---------------------------------------------------------------------------

def _get_default_language():
    """Read language preference from app config. Returns None for auto-detect."""
    try:
        lang = open(STT_LANGUAGE_FILE).read().strip()
        return lang if lang and lang != "auto" else None
    except (FileNotFoundError, OSError):
        return None


def _serialize_transcribe(tmp_path, language):
    # Use timeout to prevent deadlock if TTS holds the lock during barge-in.
    # If we can't acquire within 10s, proceed anyway (rare Metal crash is
    # better than guaranteed deadlock).
    acquired = _mlx_gpu_lock.acquire(timeout=10)
    try:
        return mlx_whisper.transcribe(tmp_path, path_or_hf_repo=WHISPER_MODEL, language=language)
    finally:
        if acquired:
            _mlx_gpu_lock.release()


def check_submit_trigger(text):
    stripped = text.strip()
    lower = stripped.lower().rstrip(" .,!?…")
    for trigger in SUBMIT_TRIGGERS:
        if lower.endswith(trigger):
            # Apply regex to stripped text; pattern allows trailing punctuation (#3)
            cleaned = _SUBMIT_PATTERNS[trigger].sub('', stripped)
            if cleaned != stripped:  # regex actually matched and removed something
                return cleaned.rstrip(), True
            # Fallback: strip the trigger word directly
            idx = lower.rfind(trigger)
            if idx >= 0:
                return stripped[:idx].rstrip(), True
    return text, False


def focus_target_app():
    try:
        if not os.path.exists(AUTO_FOCUS_APP):
            return
        with open(AUTO_FOCUS_APP) as f:
            app_name = f.read().strip()
        if not app_name:
            return
        if app_name not in _ALLOWED_FOCUS_APPS:
            if not re.match(r'^[A-Za-z0-9 ._-]+$', app_name):
                logger.warning("Blocked suspicious auto-focus app name: %r", app_name)
                return
        # Use native `open -a` — no System Events permission needed
        subprocess.Popen(
            ["open", "-a", app_name],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        logger.exception("focus_target_app failed")


def kill_tts():
    try:
        try:
            with open(TTS_PIDFILE) as f:
                pid = int(f.read().strip())
            if pid > 0:
                try:
                    result = subprocess.run(
                        ["ps", "-p", str(pid), "-o", "comm="],
                        capture_output=True, text=True, timeout=2,
                    )
                    comm = result.stdout.strip()
                    if comm and ("afplay" in comm or "tts" in comm or "bash" in comm):
                        os.kill(pid, signal.SIGTERM)
                except (subprocess.TimeoutExpired, ProcessLookupError, PermissionError):
                    pass
        except (FileNotFoundError, ValueError):
            pass

        subprocess.run(
            ["pkill", "-INT", "-U", str(os.getuid()), "-f", "afplay.*tts_"],
            capture_output=True, timeout=2,
        )
        subprocess.run(
            ["pkill", "-U", str(os.getuid()), "-f", "afplay.*tts_"],
            capture_output=True, timeout=2,
        )

        for path in (TTS_PIDFILE, TTS_LOCKFILE):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
    except Exception:
        logger.exception("kill_tts failed")


def press_enter():
    """Send plain Enter via CGEvent (needs Accessibility)."""
    try:
        _cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
        _cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        _cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
        _cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        _cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        _cg.CFRelease.argtypes = [ctypes.c_void_p]

        kCGSessionEventTap = 1
        kVK_Return = 0x24  # 36

        key_down = _cg.CGEventCreateKeyboardEvent(None, kVK_Return, True)
        key_up = _cg.CGEventCreateKeyboardEvent(None, kVK_Return, False)
        # Explicitly clear all modifier flags so held keys (Ctrl, Cmd, etc.)
        # don't bleed into the Enter event
        _cg.CGEventSetFlags(key_down, 0)
        _cg.CGEventSetFlags(key_up, 0)
        _cg.CGEventPost(kCGSessionEventTap, key_down)
        _cg.CGEventPost(kCGSessionEventTap, key_up)
        _cg.CFRelease(key_down)
        _cg.CFRelease(key_up)
    except Exception:
        logger.exception("press_enter failed")


async def _delayed_enter():
    await asyncio.sleep(1.0)
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, press_enter)


# ---------------------------------------------------------------------------
# Custom STT endpoint (replaces mlx_audio's built-in)
# ---------------------------------------------------------------------------

@app.post("/v1/audio/transcriptions")
@app.post("/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(default="whisper-1"),
    language: str = Form(default=None),
    response_format: str = Form(default="json"),
    hands_free: str = Form(default=None),
):
    tmp_path = None
    try:
        ext = ".wav"
        if file.filename:
            _, file_ext = os.path.splitext(file.filename)
            if file_ext:
                ext = file_ext

        # Stream upload directly to temp file (avoids double-buffering in memory)
        with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
            tmp_path = tmp.name
            total = 0
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_UPLOAD_BYTES:
                    return JSONResponse({"error": "File too large (max 100MB)"}, status_code=413)
                tmp.write(chunk)

        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(
            _transcribe_executor,
            lambda p=tmp_path, l=language: _serialize_transcribe(
                p, None if (not l or l == "auto") else l or _get_default_language()
            ),
        )
        text = result.get("text", "")
        if text.strip():
            logger.info("Transcribed: %s", text.strip())
    except Exception:
        logger.exception("Transcription failed")
        return JSONResponse({"error": "Transcription failed"}, status_code=500)
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except FileNotFoundError:
                pass

    try:
        loop = asyncio.get_running_loop()
        # NOTE: focus_target_app removed — the Swift app handles activation
        # natively via NSRunningApplication.activate() before text insertion.

        should_submit = False
        if hands_free == "true":
            # Hands-free: Swift app handles Enter — server only strips trigger words
            text, _ = check_submit_trigger(text)
        elif os.path.exists(AUTO_SUBMIT_FLAG):
            text, should_submit = check_submit_trigger(text)
            if not should_submit:
                should_submit = True  # auto-submit always sends Enter when flag set

        if should_submit:
            global _pending_enter_task
            async with _enter_lock:
                if _pending_enter_task and not _pending_enter_task.done():
                    _pending_enter_task.cancel()
                await loop.run_in_executor(None, kill_tts)
                _pending_enter_task = asyncio.create_task(_delayed_enter())
    except Exception:
        logger.exception("Post-transcription processing failed")

    if response_format == "text":
        return PlainTextResponse(text)
    return JSONResponse({"text": text})


# ---------------------------------------------------------------------------
# Custom TTS endpoint — replaces mlx_audio's /v1/audio/speech.
# Pre-generates ALL audio under _mlx_gpu_lock, then streams bytes from RAM.
# This serializes Metal GPU access with STT without holding the lock during
# HTTP transfer (avoids deadlock).
# ---------------------------------------------------------------------------

def _serialize_tts(payload: SpeechRequest) -> list[bytes]:
    """Run TTS generation under the GPU lock. Returns encoded audio chunks."""
    model = model_provider.load_model(payload.model)
    acquired = _mlx_gpu_lock.acquire(timeout=30)
    if not acquired:
        logger.warning("TTS could not acquire GPU lock within 30s; proceeding unlocked")
    try:
        chunks: list[bytes] = []
        for result in model.generate(
            payload.input,
            voice=payload.voice,
            speed=payload.speed,
            gender=payload.gender,
            pitch=payload.pitch,
            lang_code=payload.lang_code,
            ref_audio=payload.ref_audio,
            ref_text=payload.ref_text,
            temperature=payload.temperature,
            top_p=payload.top_p,
            top_k=payload.top_k,
            repetition_penalty=payload.repetition_penalty,
        ):
            buf = io.BytesIO()
            sf.write(buf, result.audio, result.sample_rate, format=payload.response_format)
            buf.seek(0)
            chunks.append(buf.getvalue())
        return chunks
    finally:
        if acquired:
            _mlx_gpu_lock.release()


@app.post("/v1/audio/speech")
async def tts_speech(payload: SpeechRequest):
    """GPU-serialized TTS: pre-generate all audio under lock, then stream."""
    loop = asyncio.get_running_loop()
    try:
        chunks = await loop.run_in_executor(
            _tts_executor,
            lambda p=payload: _serialize_tts(p),
        )
    except Exception:
        logger.exception("TTS generation failed")
        return JSONResponse({"error": "TTS generation failed"}, status_code=500)

    async def _stream(data: list[bytes]):
        for chunk in data:
            yield chunk

    return StreamingResponse(
        _stream(chunks),
        media_type=f"audio/{payload.response_format}",
        headers={
            "Content-Disposition": f"attachment; filename=speech.{payload.response_format}"
        },
    )


# ---------------------------------------------------------------------------
# Models endpoint — lists both STT and TTS models
# ---------------------------------------------------------------------------
@app.get("/v1/models")
@app.get("/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {"id": WHISPER_MODEL, "object": "model", "owned_by": "local", "type": "stt"},
            {"id": TTS_MODEL, "object": "model", "owned_by": "local", "type": "tts"},
        ],
    }


# ---------------------------------------------------------------------------
# Fix 2: Warm up TTS model on startup so the first real request is fast.
# Loads model weights, runs a short inference to populate MLX JIT cache.
# ---------------------------------------------------------------------------
@app.on_event("startup")
async def _warmup_tts():
    def _do_warmup():
        try:
            logger.info("Warming up TTS model...")
            model = model_provider.load_model(TTS_MODEL)
            # Run a minimal inference to JIT-compile the Metal kernels
            for _ in model.generate("hello", voice="af_heart", lang_code="a"):
                pass
            logger.info("TTS warm-up complete")
        except Exception:
            logger.warning("TTS warm-up failed (non-fatal)", exc_info=True)
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(_tts_executor, _do_warmup)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    port = int(os.getenv("SERVER_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, workers=1)
