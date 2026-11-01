#!/usr/bin/env python3
"""music.py -- the BarTap promo soundtrack, synthesised from nothing but numpy/scipy.

    python3 promo/music.py        # reads promo/out/cues.json, writes promo/out/soundtrack.wav

100 BPM, in C. The film's events all sit on the eighth-note grid, and `film cues` lists them.
A rising pluck for every icon that piles into the bar; a detuned, stuttering wobble while the
bar twitches; then the twitching just stops. A pen-stroke and a bell chord for the mark, then a
light I-V-vi-IV pulse under the demo with a sound on every tap, pop and click. No samples, no
downloads: oscillators, filtered noise and decaying partials, reverberated by a synthetic room.
"""
import json
import pathlib

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, fftconvolve, sosfilt

ROOT = pathlib.Path(__file__).resolve().parent
SR = 48000
BEAT = 0.6
EIGHTH = BEAT / 2
RNG = np.random.default_rng(20261101)


def hz(m):
    return 440.0 * 2 ** ((np.asarray(m, dtype=float) - 69) / 12)


def filt(x, kind, f, order=2):
    return sosfilt(butter(order, f, btype=kind, fs=SR, output="sos"), x)


def tvec(sec):
    return np.arange(int(sec * SR)) / SR


def fade(x, a=0.004, r=0.02):
    """Click-free edges."""
    na, nr = min(len(x), int(a * SR)), min(len(x), int(r * SR))
    if na:
        x[:na] *= np.linspace(0, 1, na)
    if nr:
        x[-nr:] *= np.linspace(1, 0, nr)
    return x


# ── instruments (mono) ───────────────────────────────────────────────────
def saw(f, n, phase=0.0, harmonics=24):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for k in range(1, harmonics + 1):
        if f * k > 9000:
            break
        out += np.sin(2 * np.pi * f * k * t + phase * k) / k * np.exp(-k / (harmonics * 0.8))
    return out


def pad(m, sec, att=0.8, rel=1.4, cents=(-7, 0, 6), wobble=0.0):
    """Detuned saws; `wobble` adds a slow, uneasy pitch drift (the twitching scene)."""
    n = int((sec + rel) * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for c in cents:
        f = hz(m) * 2 ** (c / 1200)
        if wobble:
            drift = 2 ** (wobble * np.sin(2 * np.pi * (3.1 + c * 0.05) * t + RNG.random() * 6) / 1200)
            ph = 2 * np.pi * np.cumsum(f * drift) / SR
            out += sum(np.sin(k * ph) / k for k in range(1, 12))
        else:
            out += saw(f, n, RNG.random() * 6)
    env = np.clip(t / att, 0, 1) ** 1.5 * np.where(t < sec, 1.0, np.exp(-(t - sec) / (rel / 4)))
    return fade(out / len(cents) * env, 0.01, 0.05)


def pluck(m, sec=0.9, bright=1.0):
    """Soft mallet: decaying harmonic partials."""
    t = tvec(sec)
    f = hz(m)
    s = np.zeros_like(t)
    for k, amp in ((1, 1.0), (2, 0.42), (3, 0.16), (4, 0.08), (6, 0.03)):
        if f * k < 15000:
            s += amp * np.sin(2 * np.pi * f * k * t) * np.exp(-t * (5 + 4 * k / bright))
    return fade(s * (1 - np.exp(-t / 0.0015)), 0.001, 0.05)


def bell(m, sec=2.5, index=1.2, ratio=3.5, decay=1.0):
    """FM bell."""
    t = tvec(sec)
    f = hz(m)
    mod = np.sin(2 * np.pi * f * ratio * t) * index * np.exp(-t / (decay * 0.4))
    s = np.sin(2 * np.pi * f * t + mod) * np.exp(-t / decay) + 0.3 * np.sin(4 * np.pi * f * t) * np.exp(-t / (decay * 0.5))
    return fade(s * (1 - np.exp(-t / 0.002)), 0.001, 0.05)


def kick(level=1.0):
    t = tvec(0.45)
    f = 46 + 90 * np.exp(-t / 0.03)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.2)
    click = filt(RNG.standard_normal(len(t)), "high", 1800) * np.exp(-t / 0.003) * 0.15
    return fade(np.tanh(1.4 * (body + click)) * level, 0.0005, 0.04)


def hat(sec=0.08, decay=0.016):
    t = tvec(sec)
    return fade(filt(RNG.standard_normal(len(t)), "high", 7500, 4) * np.exp(-t / decay) * 0.35, 0.0005, 0.01)


def bass(m, sec):
    t = tvec(sec)
    f = hz(m)
    s = np.sin(2 * np.pi * f * t) + 0.25 * np.sin(4 * np.pi * f * t)
    env = (1 - np.exp(-t / 0.005)) * (0.6 + 0.4 * np.exp(-t / 0.12))
    return fade(np.tanh(1.2 * s * env) * 0.8, 0.003, 0.04)


def sweep(sec, f0, f1, width=0.6):
    """Band-passed noise whose centre glides from f0 to f1 (overlap-add)."""
    n = int(sec * SR)
    src = RNG.standard_normal(n + 4096)
    out = np.zeros(n + 4096)
    blk, hop = 2048, 512
    win = np.hanning(blk)
    for i in range(0, n, hop):
        fc = f0 * (f1 / f0) ** (i / n)
        lo, hi = max(40, fc * (1 - width / 2)), min(20000, fc * (1 + width / 2))
        seg = sosfilt(butter(2, [lo, hi], btype="band", fs=SR, output="sos"), src[i:i + blk + 512])[256:256 + blk]
        out[i:i + len(seg)] += seg * win[:len(seg)]
    return out[:n] * np.hanning(n) * 0.5


def glitch(n):
    """A short digital stutter: a gated, bit-crushed blip at a random pitch."""
    t = tvec(0.09)
    f = [220, 330, 466, 622, 880][n % 5] * (1 + 0.02 * RNG.standard_normal())
    s = np.sign(np.sin(2 * np.pi * f * t)) * 0.5 + filt(RNG.standard_normal(len(t)), "band", [1200, 5000]) * 0.4
    s = np.round(s * 6) / 6                                      # crush
    gate = (np.floor(t / 0.012) % 2 == 0).astype(float)          # stutter
    return fade(s * gate * np.exp(-t / 0.05), 0.001, 0.01)


# ── the mix ──────────────────────────────────────────────────────────────
class Mix:
    def __init__(self, dur):
        self.n = int((dur + 4) * SR)
        self.buses = {}

    def add(self, bus, t0, sig, gain=1.0, pan=0.0):
        b = self.buses.setdefault(bus, np.zeros((2, self.n)))
        i = int(round(t0 * SR))
        m = min(len(sig), self.n - i)
        if m <= 0:
            return
        a = (pan + 1) * np.pi / 4
        b[0, i:i + m] += sig[:m] * gain * np.cos(a) * np.sqrt(2)
        b[1, i:i + m] += sig[:m] * gain * np.sin(a) * np.sqrt(2)

    def get(self, bus):
        return self.buses.get(bus, np.zeros((2, self.n)))


CHORDS = {   # voicing (MIDI), bass root
    "Am7": ([57, 60, 64, 67], 45), "Dm7b5": ([50, 53, 56, 60], 38), "Cmaj9": ([48, 55, 59, 62, 64], 36),
    "C": ([55, 60, 64, 67], 36), "G/B": ([55, 59, 62, 67], 35), "Fmaj7": ([53, 57, 60, 64], 41),
    "C/E": ([55, 60, 64, 67], 40), "F": ([53, 57, 60, 65], 41), "Gsus": ([55, 60, 62, 67], 43), "G": ([55, 59, 62, 67], 43),
}
A_MINOR_PENT = [57, 60, 62, 64, 67]
C_MAJOR_PENT = [60, 62, 64, 67, 69]


def plan(sc):
    """(start, chord, pulse?) — S1 calm, S2 uneasy, S3 resolves, S4-S7 a light I-V-vi-IV pulse."""
    s1, s2, s3, s4, s5, s6, s7 = sc
    bar = 4 * BEAT
    p = [(s1, "Am7", False), (s2, "Dm7b5", False), (s3, "Cmaj9", False)]
    for i, ch in enumerate(["C", "G/B", "Am7", "Fmaj7", "C/E", "F"]):
        p.append((s4 + i * bar, ch, True))
    p += [(s7, "Gsus", True), (s7 + bar / 2, "G", True), (s7 + bar, "C", False)]
    return p


def score(mx, sc, dur):
    p = plan(sc)
    kicks = []
    for (t0, ch, pulse), nxt in zip(p, p[1:] + [(dur, None, False)]):
        t1 = nxt[0]
        notes, root = CHORDS[ch]
        hold = t1 - t0
        last = nxt[1] is None
        if last:
            hold += 2.5
        uneasy = ch == "Dm7b5"
        level = {"Am7": 0.6, "Dm7b5": 0.7, "Cmaj9": 0.85}.get(ch, 0.75) if t0 < sc[3] else 0.75
        for j, m in enumerate(notes):
            # The twitching stops dead at S3; the resolve then swells in.
            v = pad(m, hold, att=1.0 if t0 == sc[2] else 0.6, rel=2.0 if last else 0.15 if uneasy else 1.2, wobble=28 if uneasy else 0)
            mx.add("pad", t0, v, level * 0.11, (j / max(1, len(notes) - 1) - 0.5) * 0.7)
        mx.add("sub", t0, pad(root - 12, hold, att=0.6, cents=(0,)), level * 0.10)
        if not pulse:
            continue
        # Pulse: soft kick on beats, hats on off-beats, eighth-note bass and arpeggio.
        pool = sorted(set(notes + [n + 12 for n in notes]))
        arp = [0, 2, 1, 3, 2, 4, 3, 5]
        k, t = 0, t0
        while t < t1 - 0.01:
            if k % 2 == 0:
                mx.add("drums", t, kick(0.9 if k % 4 == 0 else 0.6), 0.5)
                kicks.append(t)
            else:
                mx.add("drums", t, hat(), 0.35, 0.3)
            mx.add("bass", t, bass(root - 12 + (12 if k % 4 == 3 else 0), EIGHTH * 0.9), 0.28)
            m = pool[arp[k % len(arp)] % len(pool)] + 12
            mx.add("keys", t, pluck(m, 0.8, 0.8), 0.07 if k % 2 == 0 else 0.05, np.sin(k * 0.9) * 0.4)
            k += 1
            t += EIGHTH
    return kicks


def effects(mx, cues, sc):
    for c in cues:
        t, kind, n = c["t"], c["type"], c["n"]
        if kind == "pop":       # icons pile in: a rising pentatonic line, louder as it crowds
            m = A_MINOR_PENT[n % 5] + 12 * (n // 5)
            mx.add("fx", t, pluck(m, 0.7, 1.2), 0.10 + 0.006 * n, np.sin(n * 1.3) * 0.5)
        elif kind == "glitch":
            mx.add("fx", t, glitch(int(t * 10)), 0.06, np.sin(t * 7) * 0.7)
        elif kind == "draw":    # the pen stroke
            mx.add("hall", t, sweep(1.6, 900, 3600, 0.4), 0.10)
        elif kind == "drawn":
            for j, m in enumerate([72, 76, 79, 83]):
                mx.add("bells", t + j * 0.05, bell(m, 4.0, index=0.8, ratio=2.0, decay=1.6), 0.05, -0.3 + 0.2 * j)
        elif kind == "fly":
            mx.add("fx", t, sweep(0.7, 2500, 600, 0.5), 0.12)
        elif kind == "land":
            mx.add("bells", t, bell(84, 2.5, index=1.0, ratio=3.0, decay=0.8), 0.09)
        elif kind == "hide":    # the divider pushes icons away
            mx.add("fx", t, sweep(0.6, 3000, 500, 0.6), 0.12, -0.4)
        elif kind == "tap":     # reveal up, hide down
            mx.add("bells", t, bell(88 if n == 0 else 81, 1.6, index=0.9, ratio=3.0, decay=0.6), 0.08)
        elif kind == "item":
            mx.add("fx", t, pluck(C_MAJOR_PENT[n] + 24, 0.5, 1.4), 0.06, 0.4)
        elif kind == "click":
            mx.add("bells", t, bell(86, 1.4, index=0.9, ratio=3.0, decay=0.5), 0.07)
            mx.add("fx", t, sweep(0.4, 700, 2400, 0.5), 0.06)
        elif kind in ("card", "number"):
            m = C_MAJOR_PENT[(n + (0 if kind == "card" else 2)) % 5] + 12
            mx.add("fx", t, pluck(m, 0.8, 1.1), 0.09, -0.3 + 0.2 * n)
        elif kind == "end":     # the swell, a bell chord and a low C
            mx.add("hall", t - 1.4, sweep(1.5, 300, 4000, 0.7) * np.linspace(0, 1, int(1.5 * SR)) ** 2, 0.12)
            for j, m in enumerate([72, 76, 79, 84]):
                mx.add("bells", t + j * 0.04, bell(m, 4.5, index=0.7, ratio=2.0, decay=1.8), 0.05, -0.3 + 0.2 * j)
            tt = tvec(3.5)
            mx.add("fx", t, fade(np.sin(2 * np.pi * 65.4 * tt) * np.exp(-tt / 1.4), 0.02, 0.3), 0.3)


def ir(sec, decay, seed):
    r = np.random.default_rng(seed)
    t = tvec(sec)
    out = np.zeros((2, len(t)))
    for ch in range(2):
        z = r.standard_normal(len(t))
        w = np.clip(t / sec * 1.6, 0, 1)
        out[ch] = ((1 - w) * filt(z, "low", 7000) + w * filt(z, "low", 1500)) * np.exp(-t / decay) * (1 - np.exp(-t / 0.004))
    out = np.pad(out, ((0, 0), (int(0.02 * SR), 0)))
    return out / np.sqrt((out ** 2).sum() / 2)


def master(mx, kicks, dur):
    n = mx.n
    # Pads and bass duck under each kick.
    trig = np.zeros(n)
    for tk in kicks:
        trig[min(n - 1, int(tk * SR))] = 1
    duck = 1 - 0.35 * np.clip(fftconvolve(trig, np.exp(-np.arange(int(0.3 * SR)) / (0.12 * SR)))[:n], 0, 1)
    stereo = lambda x, kind, f: np.vstack([filt(x[0], kind, f), filt(x[1], kind, f)])
    pads = stereo(mx.get("pad"), "low", 2600)
    sub = stereo(mx.get("sub"), "low", 220)
    bs = stereo(mx.get("bass"), "low", 900)
    dry = pads * duck + sub + bs * duck + mx.get("drums") + mx.get("keys") + mx.get("fx") + mx.get("bells")
    send = mx.get("hall") + 0.4 * pads + 0.35 * mx.get("keys") + 0.5 * mx.get("bells") + 0.25 * mx.get("fx")
    h = ir(3.2, 0.85, 7)
    wet = np.vstack([fftconvolve(send[0], h[0])[:n], fftconvolve(send[1], h[1])[:n]])
    out = stereo(dry + 0.25 * wet + mx.get("hall"), "high", 30)
    m = int(dur * SR)
    out = out[:, :m]
    try:
        import pyloudnorm as pyln
        out *= 10 ** ((-16.0 - pyln.Meter(SR).integrated_loudness(out.T)) / 20)
    except Exception:
        out *= 10 ** (-19 / 20) / max(np.sqrt((out ** 2).mean()), 1e-9)
    over = np.abs(out) > 0.8
    out[over] = np.sign(out[over]) * (0.8 + 0.15 * np.tanh((np.abs(out[over]) - 0.8) / 0.15))
    t = np.arange(m) / SR
    out *= np.clip(t / 0.02, 0, 1) * np.clip((dur - t) / 1.2, 0, 1)
    pk = np.abs(out).max()
    if pk > 0.89:
        out *= 0.89 / pk
    return out


def main():
    data = json.loads((ROOT / "out" / "cues.json").read_text())
    dur, sc = float(data["duration"]), data["scenes"]
    mx = Mix(dur)
    kicks = score(mx, sc, dur)
    effects(mx, data["cues"], sc)
    out = master(mx, kicks, dur)
    path = ROOT / "out" / "soundtrack.wav"
    wavfile.write(path, SR, out.T.astype(np.float32))
    print(f"wrote {path}  {dur:.1f}s  rms {20 * np.log10(np.sqrt((out ** 2).mean()) + 1e-12):.1f} dBFS  "
          f"peak {20 * np.log10(np.abs(out).max()):.1f} dBFS")


if __name__ == "__main__":
    main()
