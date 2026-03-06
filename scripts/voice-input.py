#!/usr/bin/env python3
"""Voice input bridge: records mic -> Whisper STT -> types into active app.

Usage:
  python voice-input.py              # Speak, text is typed (no Enter)
  python voice-input.py --submit     # Auto-press Enter after typing
  python voice-input.py --loop       # Keep listening continuously

Requires: sounddevice, numpy, requests
Activate the mlx venv before running.
"""

import argparse
import io
import os
import re
import select
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty

import numpy as np
import requests
import sounddevice as sd
import soundfile as sf

STT_URL = os.getenv("STT_URL", "http://localhost:8000/v1/audio/transcriptions")
TTS_LOCKFILE = "/tmp/tts_playing.lock"
SAMPLE_RATE = 16000
SILENCE_THRESHOLD = None  # set by calibration at startup
SILENCE_DURATION = 3.0  # seconds of silence before stop recording
NOISE_MULTIPLIER = 4.0  # threshold = noise_floor × this
MIN_THRESHOLD = 0.01  # absolute minimum — above keyboard typing noise (~0.007)
TTS_WAIT_TIMEOUT = 120  # max seconds to wait for TTS before resuming mic
PIDFILE = "/tmp/tts_hook.pid"
VOICE_BARGE_IN_MULTIPLIER = 8.0  # voice barge-in threshold = noise_floor × this (higher than speech detection)
VOICE_BARGE_IN_CHUNKS = 3  # consecutive loud chunks (~300ms) to confirm voice barge-in

# Global flag to signal barge-in from the keyboard listener thread
_barge_in_event = threading.Event()


_last_barge_in = 0.0  # monotonic timestamp of last barge-in (debounce)
BARGE_IN_DEBOUNCE = 0.5  # ignore repeated barge-in within this window


def kill_tts():
    """Kill the running TTS playback and clean up lockfile."""
    # Kill afplay directly first — avoids orphan race where pkill -P misses
    # reparented children after the subshell is killed
    subprocess.run(["killall", "afplay"], capture_output=True)
    if os.path.exists(PIDFILE):
        try:
            with open(PIDFILE) as f:
                pid = int(f.read().strip())
            if pid > 0:
                # Kill entire process group so children (curl, afplay) also die
                try:
                    os.killpg(os.getpgid(pid), 9)
                except (ProcessLookupError, PermissionError):
                    # Fallback: kill just the PID
                    try:
                        os.kill(pid, 9)
                    except ProcessLookupError:
                        pass
        except (ValueError, ProcessLookupError, FileNotFoundError):
            pass
        try:
            os.remove(PIDFILE)
        except FileNotFoundError:
            pass
    # Verify afplay is actually dead, retry if not
    time.sleep(0.05)
    subprocess.run(["killall", "afplay"], capture_output=True)
    # Clean up orphaned temp WAV files from killed TTS
    for f in os.listdir("/tmp"):
        if f.startswith("tts_") and f.endswith(".wav"):
            try:
                os.remove(os.path.join("/tmp", f))
            except OSError:
                pass
    if os.path.exists(TTS_LOCKFILE):
        try:
            os.remove(TTS_LOCKFILE)
        except FileNotFoundError:
            pass


_original_term_settings = None


def _do_barge_in(source="space"):
    """Execute barge-in: kill TTS, set event, provide feedback."""
    global _last_barge_in
    now = time.monotonic()
    if now - _last_barge_in < BARGE_IN_DEBOUNCE:
        return  # debounce
    _last_barge_in = now
    print(f"\r(barge-in [{source}] — stopping TTS)\a", flush=True)  # \a = terminal bell
    kill_tts()
    _barge_in_event.set()


def _keypress_listener():
    """Background thread: read raw keypresses, trigger barge-in on space."""
    fd = sys.stdin.fileno()
    try:
        tty.setcbreak(fd)  # cbreak mode: char-at-a-time but keeps echo/signals
        while True:
            if select.select([sys.stdin], [], [], 0.2)[0]:
                ch = sys.stdin.read(1)
                if ch == " " and os.path.exists(TTS_LOCKFILE):
                    _do_barge_in("space")
                elif ch == "\x03":  # Ctrl+C
                    break
    except Exception:
        pass
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, _original_term_settings)


def _voice_barge_in_listener():
    """Background thread: sample mic energy during TTS, auto-barge-in on voice."""
    chunk_size = int(SAMPLE_RATE * 0.1)  # 100ms chunks
    consecutive_loud = 0

    while True:
        try:
            # Only listen when TTS is playing
            if not os.path.exists(TTS_LOCKFILE):
                consecutive_loud = 0
                time.sleep(0.2)
                continue

            # Open a short mic stream to sample energy
            stream = sd.InputStream(
                samplerate=SAMPLE_RATE, channels=1, dtype="float32", blocksize=chunk_size,
            )
            stream.start()
            try:
                while os.path.exists(TTS_LOCKFILE):
                    if _barge_in_event.is_set():
                        break
                    data, _ = stream.read(chunk_size)
                    energy = np.sqrt(np.mean(data**2))
                    voice_threshold = max(
                        (SILENCE_THRESHOLD or MIN_THRESHOLD) * (VOICE_BARGE_IN_MULTIPLIER / NOISE_MULTIPLIER),
                        MIN_THRESHOLD * 2,
                    )
                    if energy > voice_threshold:
                        consecutive_loud += 1
                        if consecutive_loud >= VOICE_BARGE_IN_CHUNKS:
                            _do_barge_in("voice")
                            consecutive_loud = 0
                            break
                    else:
                        consecutive_loud = 0
            finally:
                stream.stop()
                stream.close()
        except Exception:
            time.sleep(0.5)


def _restore_terminal():
    """Restore terminal settings on exit."""
    if _original_term_settings is not None:
        try:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, _original_term_settings)
        except Exception:
            pass


def calibrate_noise(duration=1.0):
    """Record ambient noise and return energy level."""
    chunk_size = int(SAMPLE_RATE * 0.1)
    chunks = int(duration / 0.1)
    stream = sd.InputStream(
        samplerate=SAMPLE_RATE, channels=1, dtype="float32", blocksize=chunk_size,
    )
    stream.start()
    energies = []
    for _ in range(chunks):
        data, _ = stream.read(chunk_size)
        energies.append(np.sqrt(np.mean(data**2)))
    stream.stop()
    stream.close()
    return np.mean(energies)


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
    speech_onset_count = 0
    SPEECH_ONSET_NEEDED = 5  # need 5 consecutive loud chunks (~500ms) to confirm speech
    # Pre-roll buffer: keep last 20 chunks (~2000ms) before speech detected
    # so word onsets aren't clipped
    pre_roll = []
    PRE_ROLL_SIZE = 20

    stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        blocksize=chunk_size,
    )
    stream.start()

    try:
        for i in range(max_chunks):
            # Abort recording if TTS starts playing
            if os.path.exists(TTS_LOCKFILE):
                print("(paused for TTS playback)", flush=True)
                break

            data, _ = stream.read(chunk_size)
            energy = np.sqrt(np.mean(data**2))

            if energy > SILENCE_THRESHOLD:
                if not has_speech:
                    # Speech onset detection: require consecutive loud chunks
                    # to filter out keyboard clicks (single-chunk spikes).
                    # Current chunk is added to pre_roll, and when onset is
                    # confirmed, all pre_roll chunks (including onset chunks)
                    # are moved to the recording buffer via chunks.extend().
                    speech_onset_count += 1
                    pre_roll.append(data.copy())
                    if len(pre_roll) > PRE_ROLL_SIZE:
                        pre_roll.pop(0)
                    if speech_onset_count >= SPEECH_ONSET_NEEDED:
                        has_speech = True
                        chunks.extend(pre_roll)
                        pre_roll.clear()
                    continue
                silent_chunks = 0
                chunks.append(data.copy())
            elif has_speech:
                # Keep silence chunks after speech started
                silent_chunks += 1
                chunks.append(data.copy())
            else:
                # Pre-speech: keep rolling buffer of recent chunks
                speech_onset_count = 0  # reset — isolated clicks won't accumulate
                pre_roll.append(data.copy())
                if len(pre_roll) > PRE_ROLL_SIZE:
                    pre_roll.pop(0)

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
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmp_path = f.name
            sf.write(tmp_path, audio, SAMPLE_RATE)
        with open(tmp_path, "rb") as f:
            resp = requests.post(
                STT_URL,
                files={"file": ("audio.wav", f, "audio/wav")},
                data={"model": "whisper-1", "language": "en"},
                timeout=30,
            )
        resp.raise_for_status()
        result = resp.json()
        return result.get("text", "").strip()
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)


ALLOWED_APPS = {"Terminal", "iTerm2", "Code", "Code - Insiders", "Electron", "Warp"}

# Process name → app bundle name (for AppleScript 'tell application' calls)
# get_frontmost_app() returns process names; AppleScript activate needs app names
PROCESS_TO_APP = {
    "Electron": "Visual Studio Code",
    "Code": "Visual Studio Code",
    "Code - Insiders": "Visual Studio Code - Insiders",
}


def get_frontmost_app():
    """Get the name of the currently focused application process."""
    result = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get name of first application process whose frontmost is true'],
        capture_output=True, text=True,
    )
    return result.stdout.strip()


def app_name_for_activate(process_name):
    """Convert process name to app name for AppleScript 'tell application' calls."""
    return PROCESS_TO_APP.get(process_name, process_name)


def check_submit_trigger(text):
    """Check if text ends with a submit trigger phrase. Returns (cleaned_text, should_submit).
    If the entire text IS a trigger word (e.g. just "submit"), returns ("", True) to
    submit whatever is already in the input field (press Enter only, no new text).
    """
    lower = text.lower().rstrip(" .,!?")
    triggers = ["submit", "send it", "go ahead", "send", "enter"]
    for trigger in triggers:
        if lower.endswith(trigger):
            # Strip the trigger word and trailing whitespace/punctuation
            pattern = r'\s*\b' + re.escape(trigger) + r'[.!?,]?$'
            cleaned = re.sub(pattern, '', text.strip(), flags=re.IGNORECASE)
            return cleaned, True
    return text, False


TARGET_APP = os.getenv("VOICE_TARGET", "Code")  # default: VS Code


def type_text(text, submit=True, target_app=None):
    """Type text into the target app via clipboard paste + AppleScript."""
    target_process = target_app or TARGET_APP

    if target_process not in ALLOWED_APPS:
        print(f"Warning: target '{target_process}' not in allowed apps. Skipping.", flush=True)
        return

    current_process = get_frontmost_app()
    # Check both process name and resolved app name for match
    target_app_name = app_name_for_activate(target_process)
    current_app_name = app_name_for_activate(current_process)
    switched = current_process != target_process and current_process not in PROCESS_TO_APP.get(target_process, {target_process})

    # More robust switch detection: are we already in the target app?
    # "Electron" and "Code" both map to VS Code
    same_app = (current_process == target_process or
                app_name_for_activate(current_process) == app_name_for_activate(target_process))
    switched = not same_app

    # Single AppleScript call: activate, paste, (enter), switch back
    parts = []
    if switched:
        parts.append(f'tell application "{target_app_name}" to activate')
        parts.append('delay 0.1')
    if text:
        subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)
        parts.append('tell application "System Events" to keystroke "v" using command down')
    if submit:
        parts.append('delay 0.1')
        parts.append('tell application "System Events" to key code 36')
    if switched:
        parts.append('delay 0.1')
        parts.append(f'tell application "{current_app_name}" to activate')

    script = "\n".join(parts)
    try:
        subprocess.run(["osascript", "-e", script], check=True)
    except subprocess.CalledProcessError:
        print("Error: osascript failed. Grant Accessibility access in System Settings → Privacy & Security → Accessibility", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Voice input via local Whisper")
    parser.add_argument(
        "--hold", action="store_true", help="Hold-to-talk mode (Enter to start/stop)"
    )
    parser.add_argument(
        "--submit", action="store_true", help="Press Enter after typing (default: just type, no Enter)"
    )
    parser.add_argument(
        "--loop", action="store_true", help="Keep listening in a loop"
    )
    parser.add_argument(
        "--target",
        type=str,
        default=TARGET_APP,
        help=f"Target app to type into (default: {TARGET_APP}, env: VOICE_TARGET)",
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
    print(f"Target: {args.target}")
    print(f"Mode: {'hold-to-talk' if args.hold else 'auto-silence'}")
    print("Barge-in: press SPACE or just start speaking to interrupt TTS")

    # Calibrate to room noise (typing floor is hardcoded in MIN_THRESHOLD)
    global SILENCE_THRESHOLD
    print("Calibrating ambient noise...", end=" ", flush=True)
    noise_level = calibrate_noise(duration=1.0)
    SILENCE_THRESHOLD = max(noise_level * NOISE_MULTIPLIER, MIN_THRESHOLD)
    print(f"noise={noise_level:.4f}, threshold={SILENCE_THRESHOLD:.4f}")
    print("---")

    # Start barge-in listeners
    # Keypress listener (not in hold mode — conflicts with input())
    if not args.hold:
        import atexit
        global _original_term_settings
        _original_term_settings = termios.tcgetattr(sys.stdin.fileno())
        atexit.register(_restore_terminal)
        barge_thread = threading.Thread(target=_keypress_listener, daemon=True)
        barge_thread.start()
    # Voice-onset barge-in (works in all modes)
    voice_barge_thread = threading.Thread(target=_voice_barge_in_listener, daemon=True)
    voice_barge_thread.start()

    while True:
        try:
            _barge_in_event.clear()

            # Wait while TTS is playing to avoid feedback loop
            if os.path.exists(TTS_LOCKFILE):
                deadline = time.monotonic() + TTS_WAIT_TIMEOUT
                while os.path.exists(TTS_LOCKFILE) and time.monotonic() < deadline:
                    if _barge_in_event.is_set():
                        break
                    time.sleep(0.2)
                if time.monotonic() >= deadline:
                    print("(TTS lockfile stale, removing)", flush=True)
                    try:
                        os.remove(TTS_LOCKFILE)
                    except FileNotFoundError:
                        pass
                # Cooldown: let room echo/reverb die before recording
                # (shorter after barge-in since user wants to speak now)
                time.sleep(0.5 if _barge_in_event.is_set() else 1.5)
                continue

            if args.hold:
                audio = record_while_key_held()
            else:
                audio = record_until_silence(silence_duration=args.silence)

            if audio is None or len(audio) < SAMPLE_RATE * 0.3:
                if not args.loop:
                    break
                continue

            # Discard if TTS started during recording (audio may contain TTS bleed)
            if os.path.exists(TTS_LOCKFILE):
                print("(discarding — TTS started during recording)", flush=True)
                continue

            print("Transcribing...", flush=True)
            text = transcribe(audio)

            if text:
                # Check for spoken submit trigger at the end
                text, triggered = check_submit_trigger(text)
                submit = args.submit or triggered
                if text:
                    print(f">>> {text}{'  [submit]' if submit else ''}")
                    type_text(text, submit=submit, target_app=args.target)
                elif submit:
                    # Trigger word only (e.g. "submit") — just press Enter
                    print(">>> [submit]")
                    type_text("", submit=True, target_app=args.target)
                # Cooldown after typing to avoid echo/reverb re-recording
                time.sleep(1.0)
                # After submit, wait for ALL TTS activity to settle
                if submit:
                    print("(mic off — waiting for TTS, press SPACE to interrupt)", flush=True)
                    time.sleep(2)  # wait for Claude to respond and hook to fire
                    # Keep waiting while TTS is active, with timeout
                    deadline = time.monotonic() + TTS_WAIT_TIMEOUT
                    while time.monotonic() < deadline:
                        if _barge_in_event.is_set():
                            break
                        while os.path.exists(TTS_LOCKFILE) and time.monotonic() < deadline:
                            if _barge_in_event.is_set():
                                break
                            time.sleep(0.2)
                        if _barge_in_event.is_set():
                            break
                        # Wait 2s to see if another TTS starts
                        time.sleep(2)
                        if not os.path.exists(TTS_LOCKFILE):
                            break  # no new TTS, safe to resume
                    if time.monotonic() >= deadline:
                        print("(TTS wait timed out, resuming)", flush=True)
                        if os.path.exists(TTS_LOCKFILE):
                            kill_tts()
                    print("(mic on)", flush=True)
            else:
                print("(no speech detected)")

            if not args.loop:
                break

        except KeyboardInterrupt:
            print("\nStopped.")
            break


if __name__ == "__main__":
    main()
