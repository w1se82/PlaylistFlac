"""PlaylistFlac-analyse: BPM, beatgrid, cues en key voor een playlist, zonder Traktor.

Leest de audiobestanden alleen; schrijft niets in de bestanden zelf. De uitkomst
gaat naar een Traktor-playlist (.nml) en/of een rekordbox.xml.

  Beat This! (CPJKU, MIT)   tempo, beats en de eerste beat van de maat
  eigen fijnafstelling      BPM tot op 0,005 en het grid op de aanslag
  frasemodel (model.json)   begin van de frase van 32 beats, geleerd van
                            met de hand gezette cues
  cue-regels                laadpunt, breaks en drops (de bas valt weg of
                            komt terug), uitmixen 64 en 32 beats voor het
                            einde
  key                       uit de tags als die er al in staat, anders
                            (optioneel) een schatting

Gebruik:
  python analyse.py --check
  python analyse.py --lijst bestanden.txt --naam "ACID" --nml uit.nml --rekordbox uit.xml
                    --doen grid,cues,key,keyschatting,energie --rapport rapport.json
                    --collectie collection.nml
  python analyse.py --bijwerken uit.nml --collectie collection.nml
Voortgang gaat als JSON-regels naar stdout.
"""
import argparse
import base64
import ctypes
import hashlib
import json
import os
import re
import sys
import time
import uuid
from collections import Counter
from urllib.parse import quote
from xml.sax.saxutils import quoteattr

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SR, HOP = 22050, 256
FPS = SR / HOP
CHROMA_HOP = 4096
CKPT_MD5 = '9fdf5e3f69b9996870e7aecd69527b08'
CKPT_URLS = ['https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt',
             'https://f0k.de/pubs/2024_ismir/beat_this-final0.ckpt']   # spiegel van de maker


def say(**kw):
    print(json.dumps(kw), flush=True)


# ---------------------------------------------------------------- Beat This!

def checkpoint():
    """Pad naar het Beat This!-model; eenmalig downloaden, met controle."""
    import torch
    d = os.path.join(torch.hub.get_dir(), 'checkpoints')
    path = os.path.join(d, 'beat_this-final0.ckpt')
    if os.path.exists(path):
        return path
    os.makedirs(d, exist_ok=True)
    import shutil
    import ssl
    import urllib.request
    # De Python van python.org op een Mac kent de certificaten van het systeem
    # niet; certifi (komt mee met librosa) wel.
    try:
        import certifi
        ctx = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        ctx = ssl.create_default_context()
    last = None
    for url in CKPT_URLS:
        try:
            say(t='log', msg=f'Model ophalen: {url.split("/")[2]}')
            tmp = path + '.part'
            with urllib.request.urlopen(url, context=ctx) as resp, open(tmp, 'wb') as fh:
                shutil.copyfileobj(resp, fh)
            if hashlib.md5(open(tmp, 'rb').read()).hexdigest() != CKPT_MD5:
                os.remove(tmp)
                raise ValueError('controlegetal klopt niet')
            os.replace(tmp, path)
            return path
        except Exception as e:      # volgende bron proberen
            last = e
    raise RuntimeError(f'Beat This!-model niet te downloaden ({last})')


# ---------------------------------------------------------------- kenmerken

def features(y, need_chroma=True):
    import librosa
    S = np.abs(librosa.stft(y, n_fft=2048, hop_length=HOP))
    mel = librosa.feature.melspectrogram(S=S ** 2, sr=SR, n_mels=64, fmax=8000)
    logmel = librosa.power_to_db(mel)
    mel_f = librosa.mel_frequencies(n_mels=64, fmax=8000)
    low, high = mel_f < 150, mel_f > 1500
    f = dict(onset_full=librosa.onset.onset_strength(S=logmel, sr=SR, hop_length=HOP, aggregate=np.median),
             onset_low=librosa.onset.onset_strength(S=logmel[low], sr=SR, hop_length=HOP),
             onset_high=librosa.onset.onset_strength(S=logmel[high], sr=SR, hop_length=HOP),
             low_energy=mel[low].sum(axis=0), duration=len(y) / SR)
    del S, mel, logmel
    if need_chroma:
        yh = librosa.effects.harmonic(y, margin=3.0)
        tuning = librosa.estimate_tuning(y=yh, sr=SR)
        f['chroma'] = librosa.feature.chroma_cqt(y=yh, sr=SR, hop_length=CHROMA_HOP, tuning=tuning,
                                                 n_octaves=6, bins_per_octave=36)
        f['rms_h'] = librosa.feature.rms(y=yh, hop_length=CHROMA_HOP)[0]
    return f


def norm(x):
    x = np.asarray(x, dtype=np.float64)
    x = x - np.median(x)
    return np.clip(x, 0, None) / (np.percentile(x, 99) + 1e-9)


def comb_score(onset, bpm, phases):
    period = 60 * FPS / bpm
    k = np.arange(max(1, int((len(onset) - 1 - period) / period)))
    pos = phases[:, None] + k[None, :] * period
    return np.interp(pos, np.arange(len(onset)), onset).mean(axis=1)


def fine_bpm(onset, guess):
    """BPM (stap 0,005) die het best op de aanslagen valt; een heel getal als dat bijna even goed past."""
    best = (-1, guess, 0.0)
    for cands in (np.arange(guess - 2, guess + 2, 0.05), None):
        if cands is None:
            cands = np.arange(best[1] - 0.06, best[1] + 0.06, 0.005)
        for b in cands:
            phases = np.arange(0, 60 * FPS / b, 0.5)
            s = comb_score(onset, b, phases)
            i = int(np.argmax(s))
            if s[i] > best[0]:
                best = (float(s[i]), float(b), float(phases[i]))
    score, bpm, _ = best
    r = round(bpm)
    if abs(bpm - r) < 0.06:
        s = comb_score(onset, r, np.arange(0, 60 * FPS / r, 0.5))
        if s.max() >= 0.985 * score:
            bpm = float(r)
    return bpm


def fit_grid(beats):
    """Vast tempo door de beats van Beat This! (die staan op een raster van 20 ms)."""
    b = np.array(beats)
    dd = np.diff(b); m = np.median(dd)
    period = dd[np.abs(dd - m) < 0.25 * m].mean()
    idx = np.round((b - b[0]) / period); t0 = b[0]
    keep = np.ones(len(b), bool)
    for _ in range(3):
        A = np.c_[idx[keep], np.ones(keep.sum())]
        (period, t0), *_ = np.linalg.lstsq(A, b[keep], rcond=None)
        keep = np.abs(b - (idx * period + t0)) < 0.03
        idx = np.round((b - t0) / period)
    return 60 / period


def mp3_offset(path):
    """Seconden die Traktor later rekent dan onze decoder bij een mp3 met Xing/Info-frame.

    Onze decoder slaat dat lege eerste frame (1152 samples) en de encodervertraging
    (576 + 529 samples) over, Traktor niet. Gemeten: zonder deze correctie stond het grid
    bij zulke mp3's 33-66 ms te vroeg, met correctie allemaal binnen 20 ms.
    """
    if not path.lower().endswith('.mp3'):
        return 0.0
    try:
        with open(path, 'rb') as fh:
            raw = fh.read(10)
            skip = 0
            if raw[:3] == b'ID3':
                skip = 10 + ((raw[6] & 127) << 21 | (raw[7] & 127) << 14 | (raw[8] & 127) << 7 | (raw[9] & 127))
            fh.seek(skip)
            fr = fh.read(4096)
        i = next((k for k in range(len(fr) - 1) if fr[k] == 0xFF and fr[k + 1] & 0xE0 == 0xE0), None)
        if i is None or not any(t in fr[i:i + 200] for t in (b'Xing', b'Info')):
            return 0.0
        sr = {0: 44100, 1: 48000, 2: 32000}.get((fr[i + 2] >> 2) & 3, 44100)
        delay = 576
        lame = fr.find(b'LAME', i, i + 400)
        if lame < 0:
            lame = fr.find(b'Lavc', i, i + 400)
        if lame >= 0:
            x = fr[lame + 21:lame + 24]
            delay = (x[0] << 4) | (x[1] >> 4)
        return (1152 + delay + 529) / sr
    except Exception:
        return 0.0


# --- fijnafstelling op de aanslag ---------------------------------------------
# Hoe snel het geluid boven 1 kHz aanzwelt, per halve ms. Over alle beats van de
# track opgeteld (gevouwen op de beatlengte) geeft dat een scherpe piek op het
# begin van de aanslag: daar zet Traktor het grid. Gemeten tegen met de hand
# exact gezette grids: BPM tot op 0,001 en het grid meestal binnen 2 ms.

ATTACK_HOP = SR // 2000
ATTACK_CORR = 0.0012          # de piek valt gemiddeld 1,2 ms voor de handmatige gridlijn
ATTACK_BINS = 2000


def attack_flux(y):
    from scipy.signal import butter, sosfiltfilt
    x = sosfiltfilt(butter(2, 1000, 'high', fs=SR, output='sos'), y)
    n = len(x) // ATTACK_HOP
    le = 20 * np.log10(np.sqrt((x[:n * ATTACK_HOP].reshape(n, ATTACK_HOP) ** 2).mean(1)) + 1e-5)
    le = np.convolve(le, np.ones(3) / 3, mode='same')
    flux = np.r_[np.zeros(2), np.maximum(0, le[4:] - le[:-4]), np.zeros(2)]
    return flux, np.arange(n) * ATTACK_HOP / SR


def attack_profile(flux, tt, bpm):
    period = 60 / bpm
    bins = ((tt % period) / period * ATTACK_BINS).astype(int) % ATTACK_BINS
    prof = np.bincount(bins, flux, ATTACK_BINS) / np.maximum(1, np.bincount(bins, None, ATTACK_BINS))
    return np.convolve(np.r_[prof[-3:], prof, prof[:3]], np.ones(3) / 3, mode='same')[3:-3]


def attack_bpm(flux, tt, bpm):
    for span, step in ((0.04, 0.001), (0.001, 0.0001)):
        cand = bpm + np.arange(-span, span + step / 2, step)
        bpm = float(cand[int(np.argmax([attack_profile(flux, tt, b).max() for b in cand]))])
    return bpm


def attack_phase(flux, tt, bpm, b0, window=0.025):
    period = 60 / bpm
    prof = attack_profile(flux, tt, bpm)
    offs = np.arange(-window, window + 0.0001, 0.0005)
    ts = (b0 + offs) % period
    v = prof[(ts / period * ATTACK_BINS).astype(int) % ATTACK_BINS]
    k = int(np.argmax(v))
    # hoe zeker: is er een tweede aanslag in de buurt die bijna even sterk is?
    rest = v[np.abs(offs - offs[k]) > 0.003]
    info = dict(tweede=round(float(rest.max() / (v[k] + 1e-9)), 2) if len(rest) else 0.0,
                scherp=round(float(v[k] / (np.median(prof) + 1e-9)), 1),
                verschuiving_ms=round(float(offs[k]) * 1000, 1))
    return float(ts[k]) + ATTACK_CORR, info


def grid(f, beats, downbeats, model, y=None):
    """-> bpm, tijd van een downbeat (s)."""
    onset = 0.6 * norm(f['onset_low']) + 0.4 * norm(f['onset_full'])
    bpm = fine_bpm(onset, fit_grid(beats))
    flux = None
    if y is not None:
        flux, tt = attack_flux(y)
        bpm = attack_bpm(flux, tt, bpm)
    if abs(bpm - round(bpm)) < 0.01:     # vrijwel alles is in hele BPM gemaakt: 127.9999 is 128
        bpm = float(round(bpm))
    period = 60 / bpm
    ang = np.angle(np.mean(np.exp(2j * np.pi * np.array(beats) / period)))
    ph = (ang / (2 * np.pi)) % 1 * period
    cand = ph + np.arange(-0.04, 0.0405, 0.001)
    s = comb_score(onset, bpm, cand * FPS); k = int(np.argmax(s))
    if k < 3 or k > len(cand) - 4:      # beste punt op de rand: fijnafstelling onbetrouwbaar
        b0 = ph - model['grid_corr_bt']
    else:
        b0 = float(cand[k]) % period - model['grid_corr_kam']
    info = {}
    if flux is not None:
        b0, info = attack_phase(flux, tt, bpm, b0)
    dph = Counter(int(round((d - b0) / period)) % 4 for d in downbeats).most_common(1)[0][0] if len(downbeats) else 0
    if len(downbeats):      # hoeveel van de downbeats van Beat This! vallen op onze eerste tel
        info['maat'] = round(float(np.mean([int(round((d - b0) / period)) % 4 == dph for d in downbeats])), 2)
    return bpm, b0 + dph * period, info


# ---------------------------------------------------------------- frase

def beat_feats(f, bpm, anchor):
    beat = 60 / bpm
    k0 = int(np.ceil(-anchor / beat))
    n = int((f['duration'] - anchor) / beat) - k0
    lo, hi, full, ol = f['low_energy'], f['onset_high'], f['onset_full'], f['onset_low']
    ch, rh = f['chroma'], f['rms_h']; cfps = SR / CHROMA_HOP
    rows = []
    for i in range(n):
        t0 = anchor + (k0 + i) * beat
        a, z = int(t0 * FPS), int((t0 + beat) * FPS)
        if z >= len(lo):
            break
        ca, cz = int(t0 * cfps), max(int(t0 * cfps) + 1, int((t0 + beat) * cfps))
        c = ch[:, ca:cz].mean(axis=1) if cz <= ch.shape[1] else np.zeros(12)
        rows.append(np.r_[np.log(lo[a:z].mean() + 1e-6), np.log(hi[a:z].mean() + 1e-6),
                          np.log(full[a:z].mean() + 1e-6), ol[max(0, a - 2):a + 3].max(),
                          np.log(rh[ca:cz].mean() + 1e-6) if cz <= len(rh) else 0,
                          c / (c.sum() + 1e-9) * 3])
    return k0, np.array(rows)


def base(f, bpm, anchor):
    beat = 60 / bpm
    k0, F = beat_feats(f, bpm, anchor)
    hi = f['onset_high']; n = len(F)
    hpk = np.array([hi[max(0, int((anchor + (k0 + i) * beat) * FPS) - 2): int((anchor + (k0 + i) * beat) * FPS) + 3].max()
                    for i in range(n)])
    ch = F[:, 5:17]
    X = np.c_[F[:, :5], np.log(hpk + 1e-6), np.r_[0, np.linalg.norm(np.diff(ch, axis=0), axis=1)]]
    return k0, (X - X.mean(0)) / (X.std(0) + 1e-9)


def win_mean(X, a, b):
    n = len(X); cs = np.vstack([np.zeros(X.shape[1]), np.cumsum(X, 0)])
    out = np.zeros_like(X)
    for k in range(n):
        lo, hi = min(n, max(0, k + a)), min(n, max(0, k + b))
        if hi > lo:
            out[k] = (cs[hi] - cs[lo]) / (hi - lo)
    return out


def phrase_X(X):
    parts = []
    for w in (4, 8, 16, 32):
        before, after = win_mean(X, -w, 0), win_mean(X, 0, w)
        parts += [after - before, np.abs(after - before)]
    parts.append(X)
    return np.hstack(parts)


def phrase_anchor(f, bpm, down0, model):
    """Begin van de eerste frase van 32 beats, en hoe zeker dat is."""
    beat = 60 / bpm
    k0, X = base(f, bpm, down0)
    idx = np.arange(len(X)) + k0
    sp = phrase_X(X) @ np.array(model['phrase_coef']) + model['phrase_intercept']
    sc = np.array([sp[(idx - 4 * j) % 32 == 0].mean() for j in range(8)])
    j = int(np.argmax(sc)); srt = np.sort(sc)
    anchor = down0 + 4 * j * beat
    anchor -= np.floor(anchor / (32 * beat)) * 32 * beat
    return anchor, float((srt[-1] - srt[-2]) / (sc.std() + 1e-9))


# ---------------------------------------------------------------- cues

def bar_features(f, bpm, anchor):
    beat = 60 / bpm; bar = 4 * beat
    k0 = int(np.ceil(-anchor / bar))
    nbars = int((f['duration'] - (anchor + k0 * bar)) / bar)
    on_lo, on_hi, lo = f['onset_low'], f['onset_high'], f['low_energy']
    kick, bass, high = [], [], []
    for b in range(nbars):
        t0 = anchor + (k0 + b) * bar
        ks = []
        for q in range(4):
            fr = int((t0 + q * beat) * FPS)
            ks.append(on_lo[max(0, fr - 2): fr + 3].max() if fr < len(on_lo) else 0)
        kick.append(np.median(ks))
        a, z = int(t0 * FPS), int((t0 + bar) * FPS)
        bass.append(lo[a:z].mean() if z > a else 0)
        high.append(on_hi[a:z].mean() if z > a else 0)
    return k0, np.array(kick), np.array(bass), np.array(high)


def propose_cues(f, bpm, anchor):
    """Cues als (soort, beat t.o.v. de gridmarker). Maximaal 8."""
    k0, kick, bass, high = bar_features(f, bpm, anchor)
    n = len(kick)
    if n < 24:
        return []
    lb = np.log(bass + 1e-6); en = lb + np.log(high + 1e-6)
    active = en > np.percentile(en, 50) - 3.0
    beat_of = lambda b: (k0 + b) * 4
    act = np.where(active)[0]
    first, last = (act[0], act[-1]) if len(act) else (0, n - 1)
    cues = []
    # laadpunt: de eerste maat waarin de muziek speelt, ook als die voor het frasebegin
    # ligt (bv. 8 beats ervoor: de frases verspringen dan later in de track)
    load = beat_of(first)
    cues.append(('laad', load, 0))
    end = beat_of(last + 1)
    for back in (64, 32):
        cues.append((f'uit-{back}', int(round((end - back) / 16) * 16), 1))
    cand = []
    for b in range(8, n - 8):        # bascontrast elke 16 beats, geteld vanaf het frasebegin en vanaf het laadpunt
        x = beat_of(b)
        if (x % 16 and (x - load) % 16) or x <= load or x >= end - 64:
            continue
        cand.append((lb[b:b + 8].mean() - lb[b - 8:b].mean(), x))
    downs = sorted(c for c in cand if c[0] < -1.0)
    ups = sorted((c for c in cand if c[0] > 1.0), reverse=True)

    def pick(lst, k):
        out = []
        for _, x in lst:
            if all(abs(x - y) >= 64 for y in out):
                out.append(x)
            if len(out) == k:
                break
        return out
    cues += [('break', x, 2) for x in pick(downs, 2)]
    cues += [('drop', x, 3) for x in pick(ups, 2)]
    seen, keep = [], []
    for c in sorted(cues, key=lambda c: c[2]):
        if anchor + c[1] * 60 / bpm < -0.01 or any(abs(c[1] - s) < 4 for s in seen):
            continue
        seen.append(c[1]); keep.append(c)
    return sorted(keep[:8], key=lambda c: c[1])


# ---------------------------------------------------------------- key

PITCH = {'C': 0, 'C#': 1, 'DB': 1, 'D': 2, 'D#': 3, 'EB': 3, 'E': 4, 'F': 5, 'F#': 6, 'GB': 6,
         'G': 7, 'G#': 8, 'AB': 8, 'A': 9, 'A#': 10, 'BB': 10, 'B': 11, 'CB': 11}
CAMELOT_MAJ = {8: 0, 3: 1, 10: 2, 5: 3, 12: 4, 7: 5, 2: 6, 9: 7, 4: 8, 11: 9, 6: 10, 1: 11}
CAMELOT_MIN = {5: 0, 12: 1, 7: 2, 2: 3, 9: 4, 4: 5, 11: 6, 6: 7, 1: 8, 8: 9, 3: 10, 10: 11}
KEYNAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
RB_KEYS = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B']


def parse_key(raw):
    """Key-tekst (Gm, F#m, 8A, 10m, Mixed In Key-blok) -> 0-23 (halve tonen vanaf C, +12 mineur)."""
    s = str(raw or '').strip()
    if s.startswith('eyJ'):
        try:
            s = str(json.loads(base64.b64decode(s + '=' * (-len(s) % 4)).decode('utf-8')).get('key', '')).strip()
        except Exception:
            return None
    m = re.fullmatch(r'(\d{1,2})\s*([mdMD])', s)                    # Open Key
    if m and 1 <= int(m.group(1)) <= 12:
        num, minor = ((int(m.group(1)) + 6) % 12) + 1, m.group(2).lower() == 'm'
        return (CAMELOT_MIN if minor else CAMELOT_MAJ)[num] + 12 * minor
    m = re.fullmatch(r'0?(\d{1,2})\s*([abAB])', s)                  # Camelot
    if m and 1 <= int(m.group(1)) <= 12:
        minor = m.group(2).upper() == 'A'
        return (CAMELOT_MIN if minor else CAMELOT_MAJ)[int(m.group(1))] + 12 * minor
    m = re.fullmatch(r'([A-Ga-g][#b]?)\s*(m|min|minor|maj|major)?', s)
    if m:
        pc = PITCH.get(m.group(1).upper())
        if pc is not None:
            return pc + 12 * ((m.group(2) or '').lower() in ('m', 'min', 'minor'))
    return None


def key_from_tags(path):
    try:
        import mutagen
        tg = mutagen.File(path).tags or {}
    except Exception:
        return None
    for k in ('INITIALKEY', 'initialkey', 'TKEY', 'KEY', 'key', '----:com.apple.iTunes:initialkey'):
        if k in tg:
            v = tg[k]
            v = v[0] if isinstance(v, list) else v
            v = v.text[0] if hasattr(v, 'text') else v
            if isinstance(v, bytes):
                v = v.decode('utf-8', 'replace')
            val = parse_key(v)
            if val is not None:
                return val
    return None


KK_MAJ = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
KK_MIN = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


def key_estimate(f):
    c = f['chroma']; n = c.shape[1]
    v = c[:, int(n * .05):int(n * .95)].mean(axis=1)
    v = v / (v.sum() + 1e-9)
    best, bk = -2, 0
    for t in range(12):
        for m, prof in ((0, KK_MAJ), (1, KK_MIN)):
            r = np.corrcoef(v, np.roll(prof, t))[0, 1]
            if r > best:
                best, bk = r, t + 12 * m
    return bk


# ---------------------------------------------------------------- energy
# Overgenomen uit djtool (djlib/energy.py): energy 1-10 in de geest van Mixed In
# Key, uit absolute maten (bas, onsetdichtheid, percussie, tempo, luidheid), dus
# dezelfde waarde in welke playlist de track ook staat. Geijkt op tracks met een
# echte MIK-ENERGYLEVEL; gemiddeld zo'n 1 niveau ernaast.

ENERGY_TERMS = [('loud', -11.0, 3.5, 0.20), ('crest', 9.0, -3.0, 0.30), ('sub', 0.145, 0.055, 1.20),
                ('high', 0.0135, 0.010, 0.40), ('onset_rate', 3.05, 1.30, 0.75),
                ('perc_ratio', 0.155, 0.075, 0.60), ('bpm', 130.0, 9.0, 0.80)]
ENERGY_CENTRE, ENERGY_K = 30.6448, 0.2396
# energy -> Traktor-kleur (1 rood, 2 oranje, 3 geel, 4 groen, 5 blauw, 6 violet, 7 magenta)
ENERGY_COLOUR = {1: 5, 2: 5, 3: 5, 4: 6, 5: 6, 6: 4, 7: 4, 8: 2, 9: 2, 10: 1}
COLOUR_NAME = {1: 'rood', 2: 'oranje', 3: 'geel', 4: 'groen', 5: 'blauw', 6: 'violet', 7: 'magenta'}
RB_COLOUR = {1: '0xFF0000', 2: '0xFFA500', 3: '0xFFFF00', 4: '0x00FF00', 5: '0x0000FF', 6: '0x660099', 7: '0xFF007F'}


def energy_from_tags(path):
    try:
        import mutagen
        tg = mutagen.File(path).tags or {}
    except Exception:
        return None
    for k in ('ENERGYLEVEL', 'energylevel', 'TXXX:ENERGYLEVEL', 'ENERGY', 'energy', 'TXXX:ENERGY',
              '----:com.apple.iTunes:ENERGYLEVEL', '----:com.apple.iTunes:energylevel'):
        if k in tg:
            v = tg[k]
            v = v[0] if isinstance(v, list) else v
            v = v.text[0] if hasattr(v, 'text') else v
            if isinstance(v, bytes):
                v = v.decode('utf-8', 'replace')
            m = re.match(r'\s*(\d{1,2})\b', str(v))
            if m and 1 <= int(m.group(1)) <= 10:
                return int(m.group(1))
    return None


def energy_estimate(y, bpm=None):
    import librosa
    sr = SR
    rms = librosa.feature.rms(y=y, hop_length=512)[0]
    fr = np.flatnonzero(rms >= np.percentile(rms, 55))      # de luide kern, zonder intro/outro
    yc = y[fr[0] * 512:min(len(y), (fr[-1] + 1) * 512)]
    if len(yc) < sr * 10:
        yc = y
    S = np.abs(librosa.stft(yc, n_fft=2048))
    freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)
    total = S.sum(axis=0) + 1e-9
    band = lambda a, b: float((S[(freqs >= a) & (freqs < b)].sum(axis=0) / total).mean())
    loud = float(20 * np.log10(librosa.feature.rms(y=yc)[0].mean() + 1e-9))
    peak = float(20 * np.log10(np.abs(yc).max() + 1e-9))
    onsets = librosa.onset.onset_detect(y=yc, sr=sr, units='time')
    harm, perc = librosa.effects.hpss(yc[:sr * 60])
    ph, pp = float((harm ** 2).mean()), float((perc ** 2).mean())
    if not bpm:
        bpm = float(np.atleast_1d(librosa.beat.beat_track(y=yc, sr=sr)[0])[0])
    f = dict(loud=loud, crest=peak - loud, sub=band(20, 120), high=band(4000, 11000),
             onset_rate=len(onsets) / (len(yc) / sr), perc_ratio=pp / (pp + ph + 1e-12), bpm=float(bpm))
    z = sum(w * (f[k] - c) / s for k, c, s, w in ENERGY_TERMS) / sum(w for *_, w in ENERGY_TERMS) * 10.0
    return int(min(10, max(1, round(6 + (z - ENERGY_CENTRE) * ENERGY_K))))


# ---------------------------------------------------------------- schrijven

CUE_NAMES = {'laad': 'Laad', 'break': 'Break', 'drop': 'Drop', 'uit-64': 'Uitmix -64', 'uit-32': 'Uitmix -32'}
# Traktor-cuetypes: 0 cue, 2 fade-out, 3 laadpunt. Alleen de laatste uitmix is een
# fade-out: in automode stopt Traktor op de eerste fade-out die hij tegenkomt.
CUE_TYPES = {'laad': 3, 'uit-32': 2}
RB_CUE_RGB = {0: (0, 120, 255), 2: (255, 140, 0), 3: (255, 210, 0)}


def volume_id(drive):
    """Serienummer van de schijf, zoals Traktor het als VOLUMEID schrijft (acht hexadecimale tekens)."""
    try:
        serial = ctypes.c_uint32()
        ok = ctypes.windll.kernel32.GetVolumeInformationW(ctypes.c_wchar_p(drive + '\\'), None, 0,
                                                            ctypes.byref(serial), None, None, None, 0)
        return f'{serial.value:08x}' if ok else None
    except Exception:
        return None


def mac_volume(p):
    """Mac: (schijfnaam, pad op die schijf), zoals Traktor ze schrijft.

    /Users/jij/x.flac         -> ('Macintosh HD', '/Users/jij/x.flac')  de opstartschijf
    /Volumes/USB/Muziek/x.mp3 -> ('USB', '/Muziek/x.mp3')
    """
    parts = p.split('/')
    if len(parts) > 3 and parts[1] == 'Volumes' and os.path.realpath('/Volumes/' + parts[2]) != '/':
        return parts[2], '/' + '/'.join(parts[3:])
    root = 'Macintosh HD'
    try:                      # de echte naam van de opstartschijf staat als koppeling in /Volumes
        for v in os.listdir('/Volumes'):
            if os.path.realpath('/Volumes/' + v) == '/':
                root = v
                break
    except OSError:
        pass
    return root, p


def nml_location(p):
    """-> (VOLUME, DIR, FILE, VOLUMEID of None) voor een LOCATION in een .nml."""
    p = os.path.abspath(p).replace('\\', '/')
    if os.name == 'nt':
        drive, rest = p.split(':', 1)
        volume, vid = drive + ':', volume_id(drive + ':')
    else:
        volume, rest = mac_volume(p)
        vid = volume          # Traktor op een Mac schrijft hier ook de schijfnaam
    folder, file = rest.rsplit('/', 1)
    dirn = '/:' + '/:'.join(x for x in folder.strip('/').split('/') if x) + '/:'
    return volume, dirn, file, vid


def collection_key(volume, dirn, file):
    return f'{volume}{dirn}{file}'.lower()


def read_collection(path):
    """Wat Traktor al van elke track weet. Leest collection.nml en de backups alleen.

    Een .nml inladen overschrijft de gegevens van een track in Traktor: wat er niet
    in staat raakt hij kwijt, zoals de verwijzing naar de cover. Daarom nemen we dat
    hieruit over. COVERARTID wijst naar een plaatje in Traktors map Coverart; is die
    verwijzing al weg uit de collectie, dan staat hij vaak nog in een backup.
    """
    known = {}
    if not path or not os.path.exists(path):
        return known
    import glob
    import xml.etree.ElementTree as ET

    def entries(nml):
        for e in ET.parse(nml).getroot().find('COLLECTION'):
            loc = e.find('LOCATION')
            if loc is None or not loc.get('FILE'):
                continue
            info, album = e.find('INFO'), e.find('ALBUM')
            yield collection_key(loc.get('VOLUME', ''), loc.get('DIR', ''), loc.get('FILE')), dict(
                title=e.get('TITLE'), artist=e.get('ARTIST'),
                info=dict(info.attrib) if info is not None else {},
                album=dict(album.attrib) if album is not None else {})

    known.update(entries(path))
    top = os.path.dirname(path)
    has_art = lambda cid: os.path.exists(os.path.join(top, 'Coverart', *cid.split('/')) + '000')
    for e in known.values():      # verwijzing zonder plaatje: daar heeft niemand iets aan
        if 'COVERARTID' in e['info'] and not has_art(e['info']['COVERARTID']):
            del e['info']['COVERARTID']
    for bak in sorted(glob.glob(os.path.join(top, 'Backup', 'Collection', '*.nml')), reverse=True):
        try:
            for k, e in entries(bak):
                cid = e['info'].get('COVERARTID')
                if not cid or not has_art(cid):
                    continue
                if k not in known:
                    known[k] = dict(title=None, artist=None, info={}, album={})
                known[k]['info'].setdefault('COVERARTID', cid)
        except (ET.ParseError, OSError, TypeError):
            continue
    return known


def file_tags(path):
    """Titel, artiest, album enz. uit de tags van het muziekbestand (alleen lezen)."""
    try:
        import mutagen
        tags = mutagen.File(path, easy=True)
    except Exception:
        return {}
    if not tags or not tags.tags:
        return {}

    def get(*names):
        for n in names:
            try:
                v = tags.get(n)
            except Exception:
                v = None
            if v and str(v[0]).strip():      # geen stuurtekens: die breken de XML
                return re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', str(v[0])).strip()
        return None
    return dict(title=get('title'), artist=get('artist'), album=get('album'), genre=get('genre'),
                track=get('tracknumber'), label=get('organization', 'label'), comment=get('comment'),
                remixer=get('remixer'))


def track_data(path, key, known):
    """Wat er van een track in de .nml hoort: wat Traktor al weet, aangevuld uit de tags van het bestand."""
    old = (known or {}).get(key) or dict(title=None, artist=None, info={}, album={})
    t = file_tags(path)
    info = {k: v for k, v in (('GENRE', t.get('genre')), ('LABEL', t.get('label')),
                              ('COMMENT', t.get('comment')), ('REMIXER', t.get('remixer'))) if v}
    info.update(old['info'])
    album = {}
    if t.get('album'):
        album['TITLE'] = t['album']
    if t.get('track') and t['track'].split('/')[0].strip().isdigit():
        album['TRACK'] = t['track'].split('/')[0].strip()
    album.update(old['album'])
    return dict(title=old['title'] or t.get('title'), artist=old['artist'] or t.get('artist'), info=info, album=album)


def location_path(volume, dirn, file):
    """Het echte pad bij een LOCATION uit een .nml."""
    rest = dirn.replace('/:', '/') + file
    if os.name == 'nt':
        return volume + rest
    other = f'/Volumes/{volume}{rest}'
    return other if os.path.exists(other) else rest


def merged_info(old, duration=None, key=None, colour=None):
    """Attributen voor INFO: wat Traktor al had, met onze uitkomsten eroverheen."""
    a = dict(old)
    if duration:
        a['PLAYTIME'], a['PLAYTIME_FLOAT'] = str(int(round(duration))), f'{duration:.6f}'
    if key is not None:
        a['KEY'] = key
    if colour:
        a['COLOR'] = str(colour)
    return a


def update_export(path, known):
    """Zet in een eerder gemaakte .nml alsnog over wat Traktor al weet (zonder opnieuw te analyseren)."""
    import xml.etree.ElementTree as ET
    if os.path.basename(path).lower() == 'collection.nml':
        raise ValueError('collection.nml blijft alleen-lezen')
    tree = ET.parse(path)
    tracks = covers = 0
    for e in tree.getroot().find('COLLECTION'):
        loc = e.find('LOCATION')
        tracks += 1
        vol, dirn, file = loc.get('VOLUME', ''), loc.get('DIR', ''), loc.get('FILE', '')
        old = track_data(location_path(vol, dirn, file), collection_key(vol, dirn, file), known)
        if old['title']:
            e.set('TITLE', old['title'])
        if old['artist']:
            e.set('ARTIST', old['artist'])
        info = e.find('INFO')
        for k, v in old['info'].items():
            if k not in ('PLAYTIME', 'PLAYTIME_FLOAT', 'KEY', 'COLOR') or k not in info.attrib:
                info.set(k, v)
        covers += 'COVERARTID' in info.attrib
        if old['album'] and e.find('ALBUM') is None:
            album = ET.Element('ALBUM', old['album'])
            e.insert(list(e).index(info), album)
    with open(path, 'wb') as fh:
        fh.write(b'<?xml version="1.0" encoding="UTF-8" standalone="no" ?>\n')
        tree.write(fh, encoding='utf-8', xml_declaration=False)
    return tracks, covers


def split_name(path):
    base = os.path.splitext(os.path.basename(path))[0]
    artist, sep, title = base.partition(' - ')
    return (artist, title) if sep else ('', base)


def write_nml(path, name, rows, known=None):
    entries, keys, locs = [], [], {}
    for r in rows:
        p = os.path.abspath(r['path']).replace('\\', '/')
        folder = p.rsplit('/', 1)[0]
        if folder not in locs:       # schijfnaam/serienummer eenmaal per map opzoeken
            volume, dirn, _, vid = nml_location(p)
            locs[folder] = volume, dirn, vid
        volume, dirn, vid = locs[folder]
        file = p.rsplit('/', 1)[1]
        vida = f' VOLUMEID={quoteattr(vid)}' if vid else ''
        artist, title = split_name(p)
        old = track_data(r['path'], collection_key(volume, dirn, file), known)
        title, artist = old['title'] or title, old['artist'] or artist
        x = [f'<ENTRY TITLE={quoteattr(title)} ARTIST={quoteattr(artist)}>',
             f'<LOCATION DIR={quoteattr(dirn)} FILE={quoteattr(file)} VOLUME={quoteattr(volume)}{vida}></LOCATION>']
        if old['album']:
            x.append('<ALBUM ' + ' '.join(f'{k}={quoteattr(v)}' for k, v in old['album'].items()) + '></ALBUM>')
        info = merged_info(old['info'], r.get('duration'),
                           f'{KEYNAMES[r["key"] % 12]}{"m" if r["key"] >= 12 else ""}' if r.get('key') is not None else None,
                           ENERGY_COLOUR[r['energy']] if r.get('energy') else None)
        x.append('<INFO ' + ' '.join(f'{k}={quoteattr(v)}' for k, v in info.items()) + '></INFO>')
        if r.get('bpm'):
            x.append(f'<TEMPO BPM="{r["bpm"]:.6f}" BPM_QUALITY="100.000000"></TEMPO>')
        if r.get('key') is not None:
            x.append(f'<MUSICAL_KEY VALUE="{r["key"]}"></MUSICAL_KEY>')
        if r.get('anchor') is not None:
            x.append(f'<CUE_V2 NAME="AutoGrid" DISPL_ORDER="0" TYPE="4" START="{r["anchor"] * 1000:.6f}" LEN="0.000000" '
                     f'REPEATS="-1" HOTCUE="-1"><GRID BPM="{r["bpm"]:.6f}"></GRID></CUE_V2>')
        for h, (kind, t) in enumerate(r.get('cues', [])):
            x.append(f'<CUE_V2 NAME="{h + 1} {CUE_NAMES[kind]}" DISPL_ORDER="0" TYPE="{CUE_TYPES.get(kind, 0)}" '
                     f'START="{t * 1000:.6f}" LEN="0.000000" REPEATS="-1" HOTCUE="{h}"></CUE_V2>')
        x.append('</ENTRY>')
        entries.append('\n'.join(x)); keys.append(f'{volume}{dirn}{file}')
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="no" ?>',
           '<NML VERSION="20"><HEAD COMPANY="www.native-instruments.com" PROGRAM="Traktor Pro 4"></HEAD>',
           f'<COLLECTION ENTRIES="{len(entries)}">', *entries, '</COLLECTION>',
           '<PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="1">',
           f'<NODE TYPE="PLAYLIST" NAME={quoteattr(name)}><PLAYLIST ENTRIES="{len(keys)}" TYPE="LIST" UUID="{uuid.uuid4().hex}">',
           *[f'<ENTRY><PRIMARYKEY TYPE="TRACK" KEY={quoteattr(k)}></PRIMARYKEY></ENTRY>' for k in keys],
           '</PLAYLIST></NODE></SUBNODES></NODE></PLAYLISTS></NML>']
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(out))


def file_url(p):
    p = os.path.abspath(p).replace('\\', '/')
    if os.name != 'nt':                  # Mac: file://localhost/Users/jij/x.flac
        return 'file://localhost' + quote(p)
    drive, rest = p.split(':', 1)
    return f'file://localhost/{drive}:' + quote(rest)


def write_rekordbox(path, name, rows):
    kinds = {'.flac': 'FLAC File', '.mp3': 'MP3 File', '.wav': 'WAV File', '.aif': 'AIFF File', '.aiff': 'AIFF File', '.m4a': 'M4A File'}
    tr = []
    for i, r in enumerate(rows, 1):
        artist, title = split_name(r['path'])
        a = {'TrackID': i, 'Name': title, 'Artist': artist, 'Kind': kinds.get(os.path.splitext(r['path'])[1].lower(), 'Audio File'),
             'Location': file_url(r['path'])}
        try:
            a['Size'] = os.path.getsize(r['path'])
        except OSError:
            pass
        if r.get('duration'):
            a['TotalTime'] = int(round(r['duration']))
        if r.get('bpm'):
            a['AverageBpm'] = f'{r["bpm"]:.2f}'
        if r.get('key') is not None:
            a['Tonality'] = RB_KEYS[r['key'] % 12] + ('m' if r['key'] >= 12 else '')
        if r.get('energy'):
            a['Colour'] = RB_COLOUR[ENERGY_COLOUR[r['energy']]]
        x = ['  <TRACK ' + ' '.join(f'{k}={quoteattr(str(v))}' for k, v in a.items()) + '>']
        if r.get('anchor') is not None:
            # rekordbox: grid vanaf de eerste beat na 0 s, met de BPM zoals rekordbox hem bewaart
            bpm = round(r['bpm'], 2); beat = 60 / bpm
            k = int(np.floor(r['anchor'] / beat)); start = r['anchor'] - k * beat
            battito = ((4 - (k % 4)) % 4) + 1
            x.append(f'    <TEMPO Inizio="{start:.3f}" Bpm="{bpm:.2f}" Metro="4/4" Battito="{battito}"/>')
        for h, (kind, t) in enumerate(r.get('cues', [])):
            rgb = RB_CUE_RGB[CUE_TYPES.get(kind, 0)]
            nm = quoteattr(f'{CUE_NAMES[kind]}')
            x.append(f'    <POSITION_MARK Name={nm} Type="0" Start="{t:.3f}" Num="{h}" Red="{rgb[0]}" Green="{rgb[1]}" Blue="{rgb[2]}"/>')
            x.append(f'    <POSITION_MARK Name={nm} Type="0" Start="{t:.3f}" Num="-1"/>')    # ook als memory cue
        x.append('  </TRACK>')
        tr.append('\n'.join(x))
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<DJ_PLAYLISTS Version="1.0.0">',
           ' <PRODUCT Name="rekordbox" Version="6.0.0" Company="AlphaTheta"/>',
           f' <COLLECTION Entries="{len(tr)}">', *tr, ' </COLLECTION>', ' <PLAYLISTS>',
           '  <NODE Type="0" Name="ROOT" Count="1">',
           f'   <NODE Name={quoteattr(name)} Type="1" KeyType="0" Entries="{len(tr)}">',
           *[f'    <TRACK Key="{i}"/>' for i in range(1, len(tr) + 1)],
           '   </NODE>', '  </NODE>', ' </PLAYLISTS>', '</DJ_PLAYLISTS>']
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(out))


# ---------------------------------------------------------------- rapport

GRID_TWEEDE = 0.8      # tweede aanslag binnen 25 ms die minstens zo sterk is: twijfel over het grid
MAAT_ZEKER = 0.4       # minder downbeats van Beat This! op onze tel 1: twijfel over de maat (bij ACID klopte de maat ook bij 0.49)


def let_op(r, doen):
    """Waar je bij deze track even naar moet kijken: (niveau, tekst), niveau 2 = nalopen, 1 = ter info."""
    out = []
    if r.get('fout'):
        return [(2, f"Analyse mislukt: {r['fout']}")]
    g = r.get('grid_info') or {}
    if 'grid' in doen and r.get('bpm'):
        if g.get('tweede', 0) >= GRID_TWEEDE:
            out.append((2, 'Grid: twee aanslagen vlak bij elkaar, controleer of de lijn op de kick staat'))
        if g.get('maat', 1) < MAAT_ZEKER:
            out.append((2, 'Eerste tel van de maat onzeker, controleer waar de maat begint'))
        if r.get('zeker') is not None and r['zeker'] < 0.5:
            out.append((2, 'Begin van de frase onzeker, controleer de cues'))
        if abs(r['bpm'] - round(r['bpm'])) > 0.001:
            out.append((1, f"BPM is geen heel getal ({r['bpm']:.3f}); klopt het grid aan het eind ook?"))
        if 'cues' in doen and len(r.get('cues', [])) < 4:
            out.append((1, 'Weinig cues gevonden'))
        if r.get('mp3_ms'):
            out.append((1, f"Mp3 met infoblok: grid {r['mp3_ms']:.0f} ms verschoven zodat het in Traktor klopt"))
    if ('key' in doen or 'keyschatting' in doen):
        if r.get('key') is None:
            out.append((1, 'Geen key in de tags; laat Traktor of rekordbox de key bepalen'))
        elif r.get('key_bron') == 'geschat':
            out.append((1, 'Key geschat, nog onbetrouwbaar'))
    return out


def write_rapport(path, name, rows, doen):
    tracks = []
    for r in rows:
        k = r.get('key')
        tracks.append(dict(
            bestand=os.path.basename(r['path']),
            bpm=round(r['bpm'], 3) if r.get('bpm') else None,
            key=(KEYNAMES[k % 12] + ('m' if k >= 12 else '')) if k is not None else None, key_bron=r.get('key_bron'),
            energy=r.get('energy'), energy_bron=r.get('energy_bron'),
            kleur=COLOUR_NAME[ENERGY_COLOUR[r['energy']]] if r.get('energy') else None,
            cues=[CUE_NAMES[kind] for kind, _ in r.get('cues', [])],
            grid=r.get('grid_info') or {},
            let_op=[dict(niveau=n, tekst=t) for n, t in let_op(r, doen)]))
    with open(path, 'w', encoding='utf-8') as fh:
        json.dump(dict(naam=name, datum=time.strftime('%Y-%m-%d %H:%M'), doen=sorted(doen), tracks=tracks),
                  fh, ensure_ascii=False, indent=1)


# ---------------------------------------------------------------- onthouden

# Ophogen als de analyse andere uitkomsten geeft: dan telt het oude werk niet meer mee.
CACHE_VERSIE = 1


def cache_key(p):
    return os.path.normcase(os.path.abspath(p))


def file_stamp(p):
    st = os.stat(p)
    return dict(size=st.st_size, mtime=st.st_mtime)


def load_cache(path):
    try:
        with open(path, encoding='utf-8') as fh:
            c = json.load(fh)
        return c if isinstance(c, dict) else {}
    except (OSError, ValueError):
        return {}


def save_cache(path, cache):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:     # numpy-getallen als gewone getallen
        json.dump(cache, fh, ensure_ascii=False, default=float)
    os.replace(tmp, path)


def from_cache(cache, p, doen):
    """Het eerdere resultaat van deze track, of None als dat er niet is of niet meer klopt."""
    e = cache.get(cache_key(p))
    if not e or e.get('versie') != CACHE_VERSIE or not doen <= set(e.get('doen', [])):
        return None
    if {k: e.get(k) for k in ('size', 'mtime')} != file_stamp(p):
        return None
    r = dict(e['row'], path=p)
    r['cues'] = [tuple(c) for c in r.get('cues', [])]
    if 'grid' not in doen:                # alleen teruggeven wat nu gevraagd is
        for k in ('bpm', 'anchor', 'zeker', 'mp3_ms', 'grid_info'):
            r.pop(k, None)
    if 'cues' not in doen:
        r.pop('cues', None)
    if 'energie' not in doen:
        r.pop('energy', None); r.pop('energy_bron', None)
    if 'keyschatting' not in doen and (r.get('key_bron') == 'geschat' or 'key' not in doen):
        r['key'] = None; r['key_bron'] = None
    return r


def to_cache(cache, p, r, doen):
    row = {k: v for k, v in r.items() if k != 'path'}
    cache[cache_key(p)] = dict(file_stamp(p), versie=CACHE_VERSIE, doen=sorted(doen), row=row)


def seed_cache(cache, nml, rapport):
    """Neemt de uitkomsten over uit de .nml en het rapport van een eerdere analyse van deze playlist."""
    if not nml or not rapport or not os.path.exists(nml) or not os.path.exists(rapport):
        return
    import xml.etree.ElementTree as ET
    try:
        with open(rapport, encoding='utf-8') as fh:
            rap = json.load(fh)
        klaar = time.mktime(time.strptime(rap['datum'], '%Y-%m-%d %H:%M')) + 60
        doen = sorted(rap['doen'])
        entries = ET.parse(nml).getroot().find('COLLECTION')
    except (OSError, ValueError, KeyError, ET.ParseError):
        return
    info = {t['bestand']: t for t in rap.get('tracks', [])}
    kinds = {v: k for k, v in CUE_NAMES.items()}
    for e in entries:
        loc = e.find('LOCATION')
        p = location_path(loc.get('VOLUME', ''), loc.get('DIR', ''), loc.get('FILE', ''))
        grid_cue = next((c for c in e.findall('CUE_V2') if c.get('TYPE') == '4'), None)
        t = info.get(loc.get('FILE'))
        tempo, mk, inf = e.find('TEMPO'), e.find('MUSICAL_KEY'), e.find('INFO')
        if cache_key(p) in cache or grid_cue is None or t is None or tempo is None or not os.path.exists(p):
            continue
        if os.path.getmtime(p) > klaar:    # bestand veranderd na die analyse
            continue
        row = dict(bpm=float(tempo.get('BPM')), anchor=float(grid_cue.get('START')) / 1000,
                   key=int(mk.get('VALUE')) if mk is not None else None, key_bron=t.get('key_bron'),
                   energy=t.get('energy'), energy_bron=t.get('energy_bron'), grid_info=t.get('grid') or {},
                   cues=[(kinds[c.get('NAME').split(' ', 1)[1]], float(c.get('START')) / 1000)
                         for c in e.findall('CUE_V2') if c.get('TYPE') != '4'])
        if inf is not None and inf.get('PLAYTIME_FLOAT'):
            row['duration'] = float(inf.get('PLAYTIME_FLOAT'))
        for n in t.get('let_op', []):      # wat er te controleren viel, blijft te controleren
            if n['tekst'].startswith('Begin van de frase onzeker'):
                row['zeker'] = 0.0
            m = re.match(r'Mp3 met infoblok: grid (\d+) ms', n['tekst'])
            if m:
                row['mp3_ms'] = float(m.group(1))
        to_cache(cache, p, row, doen)


# ---------------------------------------------------------------- hoofdlijn

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--lijst'); ap.add_argument('--naam', default='PlaylistFlac')
    ap.add_argument('--nml'); ap.add_argument('--rekordbox'); ap.add_argument('--rapport')
    ap.add_argument('--nml-nieuw', help='nog een .nml met alleen de tracks die deze keer geanalyseerd zijn')
    ap.add_argument('--doen', default='grid,cues,key')
    ap.add_argument('--collectie', help='collection.nml van Traktor (alleen lezen): cover, genre enz. overnemen')
    ap.add_argument('--bijwerken', help='een eerder gemaakte .nml bijwerken uit --collectie, zonder analyse')
    ap.add_argument('--cache', help='hier onthouden welke tracks al geanalyseerd zijn')
    ap.add_argument('--opnieuw', action='store_true', help='ook tracks die al geanalyseerd zijn opnieuw doen')
    a = ap.parse_args()

    if a.bijwerken:
        tracks, covers = update_export(a.bijwerken, read_collection(a.collectie))
        say(t='klaar', tracks=tracks, covers=covers, nml=a.bijwerken)
        return

    if a.check:
        import torch, librosa, mutagen, beat_this  # noqa: F401  - alles aanwezig?
        say(t='log', msg=f'Python {sys.version.split()[0]}, torch {torch.__version__}, librosa {librosa.__version__}')
        checkpoint()
        say(t='klaar', msg='Analyse is klaar voor gebruik')
        return

    doen = set(a.doen.split(','))
    if 'cues' in doen:
        doen.add('grid')
    files = [l.strip() for l in open(a.lijst, encoding='utf-8-sig') if l.strip()]
    model = json.load(open(os.path.join(HERE, 'model.json'), encoding='utf-8'))
    audio_needed = bool(doen & {'grid', 'keyschatting', 'energie'})
    librosa = bt = None        # pas laden als er echt iets te analyseren valt
    cache = load_cache(a.cache) if a.cache else {}
    if a.cache:
        seed_cache(cache, a.nml, a.rapport)

    rows = []
    for i, p in enumerate(files, 1):
        t0 = time.time()
        r = dict(path=p)
        try:
            old = from_cache(cache, p, doen) if (a.cache and not a.opnieuw) else None
            if old is not None:
                old['_bewaard'] = True
                rows.append(old)
                say(t='track', i=i, n=len(files), naam=os.path.basename(p), bewaard=True)
                continue
            if audio_needed and librosa is None:
                import librosa
                if 'grid' in doen:
                    from beat_this.inference import Audio2Beats
                    bt = Audio2Beats(checkpoint_path=checkpoint(), device='cpu', dbn=False)
            key = key_from_tags(p) if ('key' in doen or 'keyschatting' in doen) else None
            r['key_bron'] = 'tags' if key is not None else None
            if 'energie' in doen:
                r['energy'] = energy_from_tags(p)
                r['energy_bron'] = 'tags' if r['energy'] else None
            if audio_needed and ('grid' in doen or (key is None and 'keyschatting' in doen)
                                 or ('energie' in doen and not r['energy'])):
                y, _ = librosa.load(p, sr=SR, mono=True)
                r['duration'] = len(y) / SR
                f = features(y, need_chroma=True)
                if 'grid' in doen:
                    beats, downs = bt(y, SR)
                    bpm, down0, r['grid_info'] = grid(f, beats, downs, model, y)
                    anchor, zeker = phrase_anchor(f, bpm, down0, model)
                    off = mp3_offset(p)              # onze tijdlijn -> die van Traktor
                    r.update(bpm=bpm, anchor=anchor + off, zeker=zeker, mp3_ms=off * 1000)
                    if 'cues' in doen:
                        r['cues'] = [(kind, anchor + off + x * 60 / bpm) for kind, x, _ in propose_cues(f, bpm, anchor)]
                if key is None and 'keyschatting' in doen:
                    key = key_estimate(f); r['key_bron'] = 'geschat'
                if 'energie' in doen and not r['energy']:
                    r['energy'] = energy_estimate(y, r.get('bpm')); r['energy_bron'] = 'geschat'
                del y, f
            r['key'] = key
            rows.append(r)
            if a.cache:                # na elke track, zodat een gestopte analyse niets kwijtraakt
                to_cache(cache, p, r, doen)
                save_cache(a.cache, cache)
            say(t='track', i=i, n=len(files), naam=os.path.basename(p), sec=round(time.time() - t0, 1),
                bpm=round(r['bpm'], 2) if r.get('bpm') else None,
                key=(KEYNAMES[key % 12] + ('m' if key >= 12 else '')) if key is not None else None,
                key_bron=r['key_bron'], cues=len(r.get('cues', [])),
                energy=r.get('energy'), energy_bron=r.get('energy_bron'),
                kleur=COLOUR_NAME[ENERGY_COLOUR[r['energy']]] if r.get('energy') else None,
                onzeker=bool(r.get('zeker') is not None and r['zeker'] < 0.5),
                nalopen=sum(n == 2 for n, _ in let_op(r, doen)))
        except Exception as e:
            say(t='fout', i=i, n=len(files), naam=os.path.basename(p), msg=str(e)[:300])
            r['fout'] = str(e)[:300]
            rows.append(r)

    if a.cache:
        save_cache(a.cache, cache)
    known = read_collection(a.collectie) if (a.nml or a.nml_nieuw) else None
    if a.nml:
        write_nml(a.nml, a.naam, rows, known)
    nieuw = [r for r in rows if not r.get('_bewaard') and not r.get('fout')]
    if a.nml_nieuw:
        # alleen wat net geanalyseerd is: importeren laat je eigen cues bij de rest met rust
        if nieuw:
            write_nml(a.nml_nieuw, a.naam + ' (nieuw)', nieuw, known)
        elif os.path.exists(a.nml_nieuw):
            os.remove(a.nml_nieuw)
    if a.rekordbox:
        write_rekordbox(a.rekordbox, a.naam, rows)
    if a.rapport:
        write_rapport(a.rapport, a.naam, rows, doen)
    say(t='klaar', n=len(rows), nieuw=len(nieuw), nml=a.nml, rekordbox=a.rekordbox)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    main()
