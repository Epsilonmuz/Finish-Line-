"""Finish Line hard-stop alarm sounds.

Design (from the alarm-sound research report):
- Harmonic tone, fundamental 660-990 Hz, 5 partials up to ~4.5 kHz, strongest
  partials within 15 dB of each other (medical-alarm style, phone-speaker friendly).
- Pulses in groups of three; pulse rate speeds up stage by stage (strongest
  urgency lever).
- Stage 1 fades in (looming), stage 2 adds 40-80 Hz roughness, stage 3 is
  ~10 pulses/s with full roughness.
- Ends with a real-world "auditory icon" (bell or door knocks).
- 5 ms ramps on every pulse: no clicks (earbud safety). Peak -1 dBFS.
- 27 s total so it still works if AlarmKit plays it only once.
Output: mono 44.1 kHz 16-bit WAV.
"""
import numpy as np
from scipy.io import wavfile

SR = 44100
TOTAL = 27.0


def db(x):
    return 10 ** (x / 20)


def tone(f0, dur, partial_db=(0, -3, -6, -8, -10)):
    t = np.arange(int(dur * SR)) / SR
    out = np.zeros_like(t)
    for k, g in enumerate(partial_db, start=1):
        if f0 * k < 5000:
            out += db(g) * np.sin(2 * np.pi * f0 * k * t)
    return out / np.max(np.abs(out))


def ramp(sig, ms=5):
    n = min(int(SR * ms / 1000), len(sig) // 2)
    w = np.ones(len(sig))
    w[:n] = np.linspace(0, 1, n)
    w[-n:] = np.linspace(1, 0, n)
    return sig * w


def rough(sig, rate, depth):
    t = np.arange(len(sig)) / SR
    return sig * (1 - depth * 0.5 * (1 + np.sin(2 * np.pi * rate * t)))


def stage(f0, start, end, pulses_per_sec, gain_from, gain_to, rough_rate=0, rough_depth=0, pitch_rise=0.0):
    """Groups of three pulses filling [start, end)."""
    buf = np.zeros(int(TOTAL * SR))
    period = 1.0 / pulses_per_sec
    on = period * 0.6
    group_gap = period * 1.5
    t = start
    i = 0
    while t + on < end:
        frac = (t - start) / max(end - start, 1e-6)
        g = db(gain_from + (gain_to - gain_from) * frac)
        f = f0 * (1 + pitch_rise * frac)
        p = tone(f, on)
        if rough_rate:
            p = rough(p, rough_rate, rough_depth)
        p = ramp(p) * g
        s = int(t * SR)
        buf[s:s + len(p)] += p[: len(buf) - s]
        i += 1
        t += period
        if i % 3 == 0:
            t += group_gap
    return buf


def bell(f0, start, dur=3.0, gain=-3):
    """Inharmonic struck-bell icon."""
    buf = np.zeros(int(TOTAL * SR))
    t = np.arange(int(dur * SR)) / SR
    ratios = [1.0, 2.0, 2.76, 5.40, 8.93]
    amps = [1.0, 0.6, 0.5, 0.3, 0.2]
    s_ = sum(a * np.exp(-t * (1.2 + k)) * np.sin(2 * np.pi * f0 * r * t)
             for k, (r, a) in enumerate(zip(ratios, amps)))
    s_ = ramp(s_ / np.max(np.abs(s_)), 3) * db(gain)
    s = int(start * SR)
    buf[s:s + len(s_)] += s_[: len(buf) - s]
    return buf


def knocks(start, gain=-2):
    """Three firm door knocks (filtered noise thumps)."""
    rng = np.random.default_rng(7)
    buf = np.zeros(int(TOTAL * SR))
    for rep in range(2):
        for k in range(3):
            n = int(0.09 * SR)
            t = np.arange(n) / SR
            body = np.sin(2 * np.pi * 180 * t) * 0.6 + np.sin(2 * np.pi * 1200 * t) * 0.4
            hit = (body + 0.3 * rng.standard_normal(n)) * np.exp(-t * 45)
            hit = ramp(hit / np.max(np.abs(hit)), 1) * db(gain)
            s = int((start + rep * 1.4 + k * 0.28) * SR)
            buf[s:s + n] += hit[: len(buf) - s]
    return buf


def build(name, f0, rough_rate, icon, snooze=False):
    x = np.zeros(int(TOTAL * SR))
    # Stage 1: gentle, looming fade-in, ~2.5 pulses/s
    if snooze:  # snooze: different sound, starts at stage-2 intensity
        x += stage(f0, 0.0, 8.0, 5.0, -8, -5, rough_rate, 0.6)
    else:
        x += stage(f0, 0.0, 8.0, 2.5, -26, -10)
    # Stage 2: faster, roughness added, ~5 pulses/s
    x += stage(f0, 8.5, 16.5, 5.0, -8, -4, rough_rate, 0.6)
    # Stage 3: ~10 pulses/s, full roughness, slight pitch climb
    x += stage(f0, 17.0, 23.5, 10.0, -3, -1, rough_rate, 0.85, pitch_rise=0.06)
    # Icon ending
    x += bell(f0 / 2, 23.8) if icon == "bell" else knocks(23.8)
    x = np.tanh(1.2 * x) / np.tanh(1.2)  # gentle soft-clip
    x = x / np.max(np.abs(x)) * db(-1)
    wavfile.write(f"{name}.wav", SR, (x * 32767).astype(np.int16))


def wrapup():
    """30-minute warning: soft two-note chime, 4 s."""
    global TOTAL
    TOTAL = 4.0
    x = bell(660, 0.0, 2.5, -6) + bell(880, 0.6, 3.0, -8)
    x = x / np.max(np.abs(x)) * db(-6)
    wavfile.write("FL_WrapUp.wav", SR, (x * 32767).astype(np.int16))
    TOTAL = 27.0


if __name__ == "__main__":
    build("FL_HardStop_A_880_bell", 880, 60, "bell")
    build("FL_HardStop_B_740_knock", 740, 45, "knock")
    build("FL_HardStop_C_988_bell", 988, 75, "bell")
    build("FL_HardStop_D_660_knock", 660, 55, "knock")
    build("FL_Snooze_E_830_bell", 830, 65, "bell", snooze=True)
    wrapup()
