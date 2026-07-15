#!/usr/bin/env python3
"""Generate Numa's original deterministic production sound themes."""

from __future__ import annotations

import math
import struct
from pathlib import Path


SAMPLE_RATE = 16_000
ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "Resources" / "NumaSounds"


def clamp(value: float, low: float = -1.0, high: float = 1.0) -> float:
    return min(max(value, low), high)


def envelope(index: int, count: int, attack_seconds: float, release_seconds: float) -> float:
    attack = max(1, round(attack_seconds * SAMPLE_RATE))
    release = max(1, round(release_seconds * SAMPLE_RATE))
    attack_gain = min(1.0, index / attack)
    release_gain = min(1.0, (count - 1 - index) / release)
    return max(0.0, min(attack_gain, release_gain))


def sine(phase: float) -> float:
    return math.sin(2.0 * math.pi * phase)


def extended_80(value: float) -> bytes:
    """Encode a positive finite value in AIFF's 80-bit extended format."""
    exponent = math.floor(math.log2(value))
    fraction = value / (2.0**exponent)
    biased_exponent = exponent + 16_383
    mantissa = int(fraction * (2**63))
    return struct.pack(">HQ", biased_exponent, mantissa)


def write_aiff(path: Path, samples: list[float]) -> None:
    pcm = b"".join(
        struct.pack(">h", round(clamp(sample) * 32_767.0)) for sample in samples
    )
    comm = struct.pack(">hIh", 1, len(samples), 16) + extended_80(SAMPLE_RATE)
    ssnd = struct.pack(">II", 0, 0) + pcm
    form_size = 4 + (8 + len(comm)) + (8 + len(ssnd))
    payload = (
        b"FORM"
        + struct.pack(">I", form_size)
        + b"AIFF"
        + b"COMM"
        + struct.pack(">I", len(comm))
        + comm
        + b"SSND"
        + struct.pack(">I", len(ssnd))
        + ssnd
    )
    path.write_bytes(payload)


def render(duration: float, sample_at) -> list[float]:
    count = round(duration * SAMPLE_RATE)
    return [sample_at(index, index / SAMPLE_RATE, count) for index in range(count)]


def crystal_activation() -> list[float]:
    def sample(i: int, t: float, count: int) -> float:
        env = envelope(i, count, 0.008, 0.095) * math.exp(-2.2 * t)
        return 0.42 * env * (sine(1_320 * t) + 0.42 * sine(1_980 * t))

    return render(0.180, sample)


def crystal_finish() -> list[float]:
    def sample(i: int, t: float, count: int) -> float:
        progress = i / max(1, count - 1)
        frequency = 1_180 - 460 * progress
        phase = 1_180 * t - 230 * t * progress
        env = envelope(i, count, 0.010, 0.150) * math.exp(-1.4 * t)
        return 0.44 * env * (sine(phase) + 0.30 * sine(2 * frequency * t))

    return render(0.320, sample)


def pulse_activation() -> list[float]:
    centers = (0.035, 0.095, 0.155)

    def sample(i: int, t: float, count: int) -> float:
        pulse = sum(math.exp(-((t - center) / 0.018) ** 2) for center in centers)
        return 0.48 * pulse * (sine(420 * t) + 0.24 * sine(840 * t))

    return render(0.210, sample)


def pulse_finish() -> list[float]:
    centers = (0.045, 0.125, 0.215, 0.305)

    def sample(i: int, t: float, count: int) -> float:
        pulse = sum(
            (1.0 - 0.16 * idx) * math.exp(-((t - center) / 0.026) ** 2)
            for idx, center in enumerate(centers)
        )
        return 0.45 * pulse * (sine(310 * t) + 0.18 * sine(620 * t))

    return render(0.390, sample)


def organic_activation() -> list[float]:
    def sample(i: int, t: float, count: int) -> float:
        vibrato = 7.0 * sine(5.2 * t)
        phase = 540 * t + vibrato / 5.2
        env = envelope(i, count, 0.018, 0.090)
        return 0.46 * env * (sine(phase) + 0.22 * sine(2 * phase))

    return render(0.220, sample)


def organic_finish() -> list[float]:
    def sample(i: int, t: float, count: int) -> float:
        progress = i / max(1, count - 1)
        phase = 500 * t - 125 * t * progress + 0.012 * sine(4.0 * t)
        env = envelope(i, count, 0.020, 0.180)
        breath = sine(91 * t) * sine(137 * t) * 0.045
        return 0.46 * env * (sine(phase) + 0.20 * sine(2.01 * phase) + breath)

    return render(0.430, sample)


def digital_activation() -> list[float]:
    notes = (700.0, 1_050.0, 1_400.0, 1_750.0)

    def sample(i: int, t: float, count: int) -> float:
        note = notes[min(len(notes) - 1, int(t / 0.040))]
        local = t % 0.040
        env = envelope(i, count, 0.003, 0.020) * math.exp(-8.0 * local)
        quantized = round(sine(note * t) * 7.0) / 7.0
        return 0.48 * env * quantized

    return render(0.160, sample)


def digital_finish() -> list[float]:
    notes = (1_400.0, 1_050.0, 700.0, 525.0)

    def sample(i: int, t: float, count: int) -> float:
        note_index = min(len(notes) - 1, int(t / 0.090))
        note = notes[note_index]
        local = t % 0.090
        decay = math.exp(-7.0 * local)
        edge = min(1.0, local / 0.003)
        return 0.45 * edge * decay * (sine(note * t) + 0.18 * sine(2 * note * t))

    return render(0.360, sample)


ASSETS = {
    "crystal-activation.aiff": crystal_activation,
    "crystal-finish.aiff": crystal_finish,
    "pulse-activation.aiff": pulse_activation,
    "pulse-finish.aiff": pulse_finish,
    "organic-activation.aiff": organic_activation,
    "organic-finish.aiff": organic_finish,
    "digital-activation.aiff": digital_activation,
    "digital-finish.aiff": digital_finish,
}


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for filename, renderer in ASSETS.items():
        write_aiff(OUTPUT / filename, renderer())
        print(f"generated {filename}")


if __name__ == "__main__":
    main()
