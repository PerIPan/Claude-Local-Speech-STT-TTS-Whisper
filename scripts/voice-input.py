#!/usr/bin/env python3
"""Voice input bridge: records mic -> Whisper STT -> types into active app.

Usage:
  python voice-input.py              # Hold-to-talk mode (hold key, release to send)
  python voice-input.py --auto       # Auto-detect silence and submit
  python voice-input.py --no-submit  # Type text but don't press Enter

Requires: sounddevice, numpy, requests
Activate the mlx venv before running.
"""

import argparse
import io
import os
import subprocess
import sys
import tempfile
import time

import numpy as np
import sounddevice as sd
import soundfile as sf

STT_URL = os.getenv("STT_URL", "http://localhost:8000/v1/audio/transcriptions")
SAMPLE_RATE = 16000
SILENCE_THRESHOLD = 0.02
SILENCE_DURATION = 1.5  # seconds of silence before processing


def record_until_silence(silence_duration=SILENCE_DURATION, max_duration=30):
    """Record audio until silence is detected."""
    print("Listening...", flush=True)

    chunks = []
    silent_chunks = 0
    chunk_duration = 0.1  # 100ms chunks
    chunk_size = int(SAMPLE_RATE * chunk_duration)
    max_chunks = int(max_duration / chunk_duration)
    silence_chunks_needed = int(silence_duration / chunk_duration)
    has_speech = False

    stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        blocksize=chunk_size,
    )
    stream.start()

    try:
        for _ in range(max_chunks):
            data, _ = stream.read(chunk_size)
            chunks.append(data.copy())

            energy = np.sqrt(np.mean(data**2))

            if energy > SILENCE_THRESHOLD:
                has_speech = True
                silent_chunks = 0
            else:
                silent_chunks += 1

            if has_speech and silent_chunks >= silence_chunks_needed:
                break
    finally:
        stream.stop()
        stream.close()

    if not has_speech:
        return None

    audio = np.concatenate(chunks).flatten()
    # Trim trailing silence
    trim_samples = int(silence_duration * SAMPLE_RATE)
    if len(audio) > trim_samples:
        audio = audio[:-trim_samples]

    print(f"Recorded {len(audio)/SAMPLE_RATE:.1f}s of audio", flush=True)
    return audio


def record_while_key_held():
    """Record while any key is held (press Enter to start, Enter to stop)."""
    input("Press Enter to start recording...")
    print("Recording... Press Enter to stop.", flush=True)

    chunks = []
    chunk_size = int(SAMPLE_RATE * 0.1)

    stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        blocksize=chunk_size,
    )
    stream.start()

    import threading

    stop_flag = threading.Event()

    def wait_for_enter():
        input()
        stop_flag.set()

    t = threading.Thread(target=wait_for_enter, daemon=True)
    t.start()

    try:
        while not stop_flag.is_set():
            data, _ = stream.read(chunk_size)
            chunks.append(data.copy())
    finally:
        stream.stop()
        stream.close()

    if not chunks:
        return None

    audio = np.concatenate(chunks).flatten()
    print(f"Recorded {len(audio)/SAMPLE_RATE:.1f}s of audio", flush=True)
    return audio


def transcribe(audio):
    """Send audio to Whisper STT server."""
    import requests

    # Write to temp wav file
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        sf.write(f.name, audio, SAMPLE_RATE)
        tmp_path = f.name

    try:
        with open(tmp_path, "rb") as f:
            resp = requests.post(
                STT_URL,
                files={"file": ("audio.wav", f, "audio/wav")},
                data={"model": "whisper-1"},
                timeout=30,
            )
        resp.raise_for_status()
        result = resp.json()
        return result.get("text", "").strip()
    finally:
        os.unlink(tmp_path)


def type_text(text, submit=True):
    """Type text into the active application using AppleScript."""
    # Escape for AppleScript
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')

    script = f'tell application "System Events" to keystroke "{escaped}"'
    try:
        subprocess.run(["osascript", "-e", script], check=True)
    except subprocess.CalledProcessError:
        print("Error: osascript denied. Grant Accessibility access to Terminal/VS Code in System Settings → Privacy & Security → Accessibility", flush=True)
        return

    if submit:
        time.sleep(0.1)
        try:
            subprocess.run(
                [
                    "osascript",
                    "-e",
                    'tell application "System Events" to key code 36',  # Enter key
                ],
                check=True,
            )
        except subprocess.CalledProcessError:
            print("Error: could not press Enter", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Voice input via local Whisper")
    parser.add_argument(
        "--auto",
        action="store_true",
        default=True,
        help="Auto-detect silence (default)",
    )
    parser.add_argument(
        "--hold", action="store_true", help="Hold-to-talk mode (Enter to start/stop)"
    )
    parser.add_argument(
        "--no-submit", action="store_true", help="Type text but don't press Enter"
    )
    parser.add_argument(
        "--loop", action="store_true", help="Keep listening in a loop"
    )
    parser.add_argument(
        "--silence",
        type=float,
        default=SILENCE_DURATION,
        help=f"Silence duration to stop recording (default: {SILENCE_DURATION}s)",
    )
    args = parser.parse_args()

    print("Voice Input (Whisper STT)")
    print(f"Server: {STT_URL}")
    print(f"Mode: {'hold-to-talk' if args.hold else 'auto-silence'}")
    print("---")

    while True:
        try:
            if args.hold:
                audio = record_while_key_held()
            else:
                audio = record_until_silence(silence_duration=args.silence)

            if audio is None or len(audio) < SAMPLE_RATE * 0.3:
                if not args.loop:
                    break
                continue

            print("Transcribing...", flush=True)
            text = transcribe(audio)

            if text:
                print(f">>> {text}")
                type_text(text, submit=not args.no_submit)
            else:
                print("(no speech detected)")

            if not args.loop:
                break

        except KeyboardInterrupt:
            print("\nStopped.")
            break


if __name__ == "__main__":
    main()
