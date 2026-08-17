"""Procedurally synthesize 7 background-music tracks for Pulse Arena.

Each track targets a different scene (menu, match start/end) or map
(arena_cross, neon_docks, reactor_ring, skyline_yard) with a distinct
key, tempo, and instrumentation so the player can tell where they are
without looking at the HUD.

Output: 7 mono 16-bit WAV files at 22050 Hz in assets/audio/.
Run:    .venv/bin/python scripts/audio/build_bgm.py
"""
from __future__ import annotations

import math
import os
import struct
import wave
from dataclasses import dataclass
from typing import Iterable

import numpy as np

SAMPLE_RATE = 16000
OUT_DIR = "assets/audio"


# ---------- low-level oscillator + envelope helpers ---------- #

def adsr(num_frames: int, attack: float, decay: float, sustain: float, release: float) -> np.ndarray:
    """Return an ADSR envelope of the given total length (seconds per stage)."""
    a = int(attack * SAMPLE_RATE)
    d = int(decay * SAMPLE_RATE)
    r = int(release * SAMPLE_RATE)
    s = max(num_frames - (a + d + r), 1)
    env = np.zeros(num_frames, dtype=np.float32)
    if a:
        env[:a] = np.linspace(0.0, 1.0, a, endpoint=False)
    if d:
        env[a:a + d] = np.linspace(1.0, sustain, d, endpoint=False)
    env[a + d:a + d + s] = sustain
    if r:
        env[a + d + s:a + d + s + r] = np.linspace(sustain, 0.0, r, endpoint=True)
    return env


def note_sine(freq: float, duration: float, volume: float = 0.25,
              harmonics: Iterable[tuple[float, float]] = (),
              vibrato_hz: float = 0.0, vibrato_depth: float = 0.0) -> np.ndarray:
    """One tone with sine fundamental + optional harmonics + vibrato."""
    frames = int(duration * SAMPLE_RATE)
    t = np.arange(frames, dtype=np.float32) / SAMPLE_RATE
    phase = 2.0 * np.pi * freq * t
    if vibrato_hz > 0.0:
        phase += 2.0 * np.pi * vibrato_hz * t * (vibrato_depth / freq)
    s = np.sin(phase).astype(np.float32)
    for amp, mult in harmonics:
        s += amp * np.sin(phase * mult)
    s /= 1.0 + sum(amp for amp, _ in harmonics)
    env = adsr(frames, 0.01, 0.05, 0.7, 0.12)
    return s * env * volume


def note_saw(freq: float, duration: float, volume: float = 0.18,
             filter_cut: float = 0.0) -> np.ndarray:
    """Sawtooth with simple low-pass smoothing (cheap stand-in for a filter)."""
    frames = int(duration * SAMPLE_RATE)
    t = np.arange(frames, dtype=np.float32) / SAMPLE_RATE
    # anti-aliased saw via summation of partials up to nyquist
    partials = int(min(20, SAMPLE_RATE / (2.0 * freq)))
    s = np.zeros(frames, dtype=np.float32)
    for k in range(1, partials + 1):
        s += np.sin(2.0 * np.pi * freq * k * t) / k
    s *= 0.5
    if filter_cut > 0.0:
        # simple one-pole low-pass via cumulative average
        alpha = min(1.0, filter_cut)
        s = np.clip(s, -1.0, 1.0)
        out = np.zeros_like(s)
        out[0] = s[0]
        for i in range(1, frames):
            out[i] = out[i - 1] + alpha * (s[i] - out[i - 1])
        s = out
    env = adsr(frames, 0.005, 0.04, 0.6, 0.08)
    return s * env * volume


def note_triangle(freq: float, duration: float, volume: float = 0.22) -> np.ndarray:
    frames = int(duration * SAMPLE_RATE)
    t = np.arange(frames, dtype=np.float32) / SAMPLE_RATE
    phase = (freq * t) % 1.0
    s = 2.0 * np.abs(2.0 * phase - 1.0) - 1.0
    s = s.astype(np.float32)
    env = adsr(frames, 0.01, 0.05, 0.65, 0.1)
    return s * env * volume


def kick(velocity: float = 1.0) -> np.ndarray:
    """Short thump: pitched sine sweep down + click."""
    duration = 0.18
    frames = int(duration * SAMPLE_RATE)
    t = np.arange(frames, dtype=np.float32) / SAMPLE_RATE
    freq = 110.0 * np.exp(-t * 18.0) + 45.0
    s = np.sin(2.0 * np.pi * freq * t).astype(np.float32)
    s += np.random.RandomState(0).uniform(-0.2, 0.2, frames).astype(np.float32) * 0.4
    env = adsr(frames, 0.001, 0.04, 0.0, 0.06)
    return s * env * velocity * 0.5


def snare(velocity: float = 1.0) -> np.ndarray:
    duration = 0.12
    frames = int(duration * SAMPLE_RATE)
    rng = np.random.RandomState(1)
    noise = rng.uniform(-1.0, 1.0, frames).astype(np.float32)
    tone = np.sin(2.0 * np.pi * 220.0 * np.arange(frames, dtype=np.float32) / SAMPLE_RATE).astype(np.float32) * 0.3
    s = noise * 0.7 + tone
    env = adsr(frames, 0.001, 0.02, 0.0, 0.05)
    return s * env * velocity * 0.35


def hat(velocity: float = 1.0) -> np.ndarray:
    duration = 0.05
    frames = int(duration * SAMPLE_RATE)
    rng = np.random.RandomState(2)
    noise = rng.uniform(-1.0, 1.0, frames).astype(np.float32)
    env = adsr(frames, 0.001, 0.01, 0.0, 0.02)
    return noise * env * velocity * 0.18


# ---------- music theory helpers ---------- #

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def note_hz(name: str, octave: int = 4) -> float:
    """Convert e.g. "A" + 4 → 440 Hz. Uses A4=440 reference."""
    idx = NOTE_NAMES.index(name)
    midi = (octave + 1) * 12 + idx
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


def chord(root: str, quality: str, octave: int = 4) -> list[float]:
    """Return MIDI intervals for a chord (root, third, fifth, optional 7th)."""
    intervals = {
        "maj": [0, 4, 7],
        "min": [0, 3, 7],
        "dim": [0, 3, 6],
        "maj7": [0, 4, 7, 11],
        "min7": [0, 3, 7, 10],
        "sus4": [0, 5, 7],
    }[quality]
    root_hz = note_hz(root, octave)
    return [root_hz * (2.0 ** (iv / 12.0)) for iv in intervals]


# ---------- track composer ---------- #

@dataclass
class Track:
    name: str
    bpm: float
    bars: int
    beats_per_bar: int
    progression: list[tuple[str, str]]  # list of (root, quality)
    bass_octave: int
    pad_octave: int
    lead_octave: int
    melody_steps: list[int]            # semitone offsets from pad root
    melody_beats: list[float]          # beat offsets within a bar
    hat_on_every: int                  # 1 = every beat, 2 = offbeats, 0 = no hat
    kick_pattern: list[bool]           # len=beats_per_bar
    snare_pattern: list[bool]
    waveform_lead: str                 # 'sine' / 'saw' / 'triangle'
    waveform_bass: str
    filter_cut: float
    loop_seconds: float                # final length to enforce


def render_track(t: Track) -> np.ndarray:
    seconds_per_beat = 60.0 / t.bpm
    seconds_per_bar = seconds_per_beat * t.beats_per_bar
    total_seconds = t.bars * seconds_per_bar
    # Snap loop to whole bars.
    total_seconds = round(total_seconds, 3)
    frames = int(total_seconds * SAMPLE_RATE)
    mix = np.zeros(frames, dtype=np.float32)

    # Bass: root of each chord on beat 1, sustained for one bar.
    bass_step = int(seconds_per_bar * SAMPLE_RATE)
    for bar in range(t.bars):
        root, quality = t.progression[bar % len(t.progression)]
        bass_notes = chord(root, quality, t.bass_octave)
        bass_freq = bass_notes[0]
        if t.waveform_bass == "saw":
            tone = note_saw(bass_freq, seconds_per_bar, volume=0.32, filter_cut=t.filter_cut)
        else:
            tone = note_sine(bass_freq, seconds_per_bar, volume=0.32)
        start = bar * bass_step
        end = min(start + bass_step, frames)
        mix[start:end] += tone[:end - start]

    # Pad chord on every bar, slow attack.
    for bar in range(t.bars):
        root, quality = t.progression[bar % len(t.progression)]
        pad_notes = chord(root, quality, t.pad_octave)
        for n in pad_notes:
            tone = note_sine(n, seconds_per_bar, volume=0.10,
                             harmonics=[(0.18, 2), (0.06, 3)])
            start = bar * bass_step
            end = min(start + bass_step, frames)
            mix[start:end] += tone[:end - start]

    # Lead melody: same phrase on every bar (so it loops cleanly).
    lead_step = int(seconds_per_beat * SAMPLE_RATE)
    for bar in range(t.bars):
        root, quality = t.progression[bar % len(t.progression)]
        root_hz = note_hz(root, t.lead_octave)
        for step, beat in zip(t.melody_steps, t.melody_beats):
            if step is None:
                continue
            freq = root_hz * (2.0 ** (step / 12.0))
            dur = seconds_per_beat * 0.85
            if t.waveform_lead == "saw":
                tone = note_saw(freq, dur, volume=0.22, filter_cut=t.filter_cut)
            elif t.waveform_lead == "triangle":
                tone = note_triangle(freq, dur, volume=0.28)
            else:
                tone = note_sine(freq, dur, volume=0.28,
                                 harmonics=[(0.25, 2)], vibrato_hz=5.5, vibrato_depth=6.0)
            start = bar * bass_step + int(beat * seconds_per_beat * SAMPLE_RATE)
            end = min(start + int(dur * SAMPLE_RATE), frames)
            if start >= frames:
                continue
            mix[start:end] += tone[:end - start]

    # Drums.
    if any(t.kick_pattern) or any(t.snare_pattern):
        for bar in range(t.bars):
            for beat in range(t.beats_per_bar):
                beat_frame = bar * bass_step + beat * lead_step
                if beat_frame >= frames:
                    continue
                if t.kick_pattern[beat % len(t.kick_pattern)]:
                    mix[beat_frame:beat_frame + len(kick())] += kick()[:frames - beat_frame]
                if t.snare_pattern[beat % len(t.snare_pattern)]:
                    mix[beat_frame:beat_frame + len(snare())] += snare()[:frames - beat_frame]
                if t.hat_on_every and beat % t.hat_on_every == 0:
                    mix[beat_frame:beat_frame + len(hat())] += hat()[:frames - beat_frame]

    # Soft limiter + master gain.
    mix = np.tanh(mix * 1.4) * 0.75
    return mix


def write_wav(path: str, samples: np.ndarray) -> None:
    samples_int16 = np.clip(samples, -1.0, 1.0)
    samples_int16 = (samples_int16 * 32767.0).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(samples_int16.tobytes())
    print(f"  wrote {path}  ({len(samples_int16)} samples = {len(samples_int16) / SAMPLE_RATE:.1f}s, "
          f"{os.path.getsize(path) / 1024:.1f} KiB)")


# ---------- track definitions ---------- #

TRACKS = [
    Track(
        name="bgm_menu.wav",
        bpm=72, bars=4, beats_per_bar=4,
        progression=[("F", "maj7"), ("C", "maj7"), ("A#", "maj7"), ("G", "min7")],
        bass_octave=2, pad_octave=4, lead_octave=5,
        melody_steps=[0, 4, 7, 11, None, 7, 4, None],
        melody_beats=[0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5],
        hat_on_every=0, kick_pattern=[], snare_pattern=[],
        waveform_lead="sine", waveform_bass="sine", filter_cut=0.0,
        loop_seconds=0,
    ),
    Track(
        name="bgm_match_start.wav",
        bpm=108, bars=4, beats_per_bar=4,
        progression=[("A", "min"), ("F", "maj"), ("C", "maj"), ("G", "maj")],
        bass_octave=2, pad_octave=4, lead_octave=5,
        melody_steps=[0, 3, 5, 7, 5, 3, 0, None],
        melody_beats=[0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5],
        hat_on_every=2, kick_pattern=[True, False, False, False], snare_pattern=[False, False, True, False],
        waveform_lead="saw", waveform_bass="saw", filter_cut=0.45,
        loop_seconds=0,
    ),
    Track(
        name="bgm_match_end.wav",
        bpm=66, bars=4, beats_per_bar=4,
        progression=[("D", "maj"), ("A", "maj"), ("G", "maj"), ("D", "maj")],
        bass_octave=2, pad_octave=4, lead_octave=5,
        melody_steps=[0, 2, 4, 7, 4, 2, 0, None],
        melody_beats=[0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5],
        hat_on_every=0, kick_pattern=[], snare_pattern=[],
        waveform_lead="sine", waveform_bass="sine", filter_cut=0.0,
        loop_seconds=0,
    ),
    Track(
        name="bgm_arena_cross.wav",
        bpm=120, bars=4, beats_per_bar=4,
        progression=[("A", "min"), ("F", "maj"), ("C", "maj"), ("G", "maj")],
        bass_octave=2, pad_octave=4, lead_octave=5,
        melody_steps=[0, 3, 7, 10, 7, 3, 0, None],
        melody_beats=[0.0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 2.5],
        hat_on_every=1, kick_pattern=[True, False, True, False], snare_pattern=[False, False, True, False],
        waveform_lead="saw", waveform_bass="saw", filter_cut=0.6,
        loop_seconds=0,
    ),
    Track(
        name="bgm_neon_docks.wav",
        bpm=82, bars=4, beats_per_bar=4,
        progression=[("F#", "min7"), ("D", "min7"), ("A", "min7"), ("E", "min7")],
        bass_octave=2, pad_octave=4, lead_octave=5,
        melody_steps=[0, 3, 5, None, 7, 5, 3, None],
        melody_beats=[0.0, 0.75, 1.5, 2.0, 2.5, 3.0, 3.25, 3.5],
        hat_on_every=2, kick_pattern=[True, False, False, False], snare_pattern=[False, True, False, True],
        waveform_lead="triangle", waveform_bass="triangle", filter_cut=0.2,
        loop_seconds=0,
    ),
    Track(
        name="bgm_reactor_ring.wav",
        bpm=132, bars=4, beats_per_bar=4,
        progression=[("E", "min"), ("C", "maj"), ("G", "maj"), ("D", "maj")],
        bass_octave=2, pad_octave=4, lead_octave=5,
        melody_steps=[0, 3, 7, 3, 0, 7, 3, 0],
        melody_beats=[0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5],
        hat_on_every=1, kick_pattern=[True, True, True, True], snare_pattern=[False, True, False, True],
        waveform_lead="saw", waveform_bass="saw", filter_cut=0.35,
        loop_seconds=0,
    ),
    Track(
        name="bgm_skyline_yard.wav",
        bpm=88, bars=4, beats_per_bar=4,
        progression=[("D", "maj"), ("A", "maj"), ("F#", "min"), ("G", "maj")],
        bass_octave=2, pad_octave=4, lead_octave=5,
        melody_steps=[0, 4, 7, 11, 7, 4, None, 7],
        melody_beats=[0.0, 1.0, 2.0, 2.5, 3.0, 3.5, 0.5, 1.5],
        hat_on_every=0, kick_pattern=[], snare_pattern=[],
        waveform_lead="sine", waveform_bass="sine", filter_cut=0.0,
        loop_seconds=0,
    ),
]


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    for t in TRACKS:
        print(f"rendering {t.name} ...")
        samples = render_track(t)
        write_wav(os.path.join(OUT_DIR, t.name), samples)


if __name__ == "__main__":
    main()
