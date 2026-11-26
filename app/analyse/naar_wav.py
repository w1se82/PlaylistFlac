"""PlaylistFlac - FLAC naar WAV voor oudere CDJ's, en een rekordbox.xml die naar die WAV's wijst.

Oudere Pioneer-spelers (van voor de CDJ-2000NXS2) spelen geen FLAC, wel WAV van
16 of 24 bit op 44,1 of 48 kHz. Sommige struikelen over WAVE_FORMAT_EXTENSIBLE, de
header die veel programma's bij 24 bit schrijven. Daarom wordt alles 16-bit/44,1 kHz
met een gewone PCM-header: dat speelt op elk model.

- 16-bit/44,1 kHz FLAC: de samples gaan ongewijzigd over (bit voor bit gelijk).
- Andere FLAC (24 bit, 48 of 96 kHz): soxr (VHQ) naar 44,1 kHz, dan naar 16 bit met
  TPDF-dither. Posities in seconden blijven gelijk, dus cues en grid kloppen.

Leest een rekordbox.xml en de muziekbestanden, schrijft alleen in --map en naar --uit.
Elke regel op stdout is JSON, voor de voortgang in PlaylistFlac.

    naar_wav.py --check
    naar_wav.py --xml in.xml --uit uit.xml --map "<muziekmap>/WAV (CDJ)" [--alleen PlaylistFlac]
"""
import argparse, json, os, re, sys
import xml.etree.ElementTree as ET
from urllib.parse import quote, unquote

sys.stdout.reconfigure(encoding='utf-8')
OUT_SR = 44100
TAGS = ('title', 'artist', 'album', 'date', 'genre', 'comment', 'tracknumber')


def say(**m):
    print(json.dumps(m, ensure_ascii=False), flush=True)


def check():
    import numpy, soundfile as sf, soxr  # noqa: F401
    if 'FLAC' not in sf.available_formats():
        raise SystemExit('libsndfile zonder FLAC')
    say(t='ok', msg=f'soundfile {sf.__version__} ({sf.__libsndfile_version__}), soxr {soxr.__version__}')


# --- paden <-> rekordbox Location ---------------------------------------------

def url_to_path(url):
    p = unquote(re.sub(r'^file://localhost', '', url))
    if re.match(r'^/[A-Za-z]:', p):          # Windows: /C:/Users/... -> C:/Users/...
        p = p[1:]
    return os.path.normpath(p)


def path_to_url(p):
    p = os.path.abspath(p).replace('\\', '/')
    if re.match(r'^[A-Za-z]:', p):
        return 'file://localhost/' + p[:2] + quote(p[2:])
    return 'file://localhost' + quote(p)


def safe_name(s):
    s = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', s).strip().rstrip('.')
    return s or 'playlist'


# --- omzetten -------------------------------------------------------------------

def wav_format_tag(path):
    with open(path, 'rb') as f:
        head = f.read(256)
    i = head.find(b'fmt ')
    return int.from_bytes(head[i + 8:i + 10], 'little') if i >= 0 else -1


def convert(src, dst):
    """Geeft (status, uitleg). Schrijft eerst naar dst.part, pas na controle naar dst."""
    import numpy as np, soundfile as sf, soxr
    tmp = dst + '.part'
    with sf.SoundFile(src) as fin:
        sr, sub, ch = fin.samplerate, fin.subtype, fin.channels
        nch = min(ch, 2)
        exact = sr == OUT_SR and sub == 'PCM_16'
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with sf.SoundFile(tmp, 'w', OUT_SR, nch, 'PCM_16', format='WAV') as fout:
            for k in TAGS:
                try:
                    v = getattr(fin, k)
                    if v:
                        setattr(fout, k, v)
                except Exception:
                    pass
            if exact:
                for block in fin.blocks(blocksize=1 << 16, dtype='int16', always_2d=True):
                    fout.write(block[:, :nch])
            else:
                rng = np.random.default_rng(0)
                rs = soxr.ResampleStream(sr, OUT_SR, nch, dtype='float32', quality='VHQ') if sr != OUT_SR else None

                def put(y):
                    if not len(y):
                        return
                    d = rng.random(y.shape, dtype=np.float32) - rng.random(y.shape, dtype=np.float32)
                    q = np.clip(np.round(y * 32768.0 + d), -32768, 32767).astype(np.int16)
                    fout.write(q)

                for block in fin.blocks(blocksize=1 << 16, dtype='float32', always_2d=True):
                    y = np.ascontiguousarray(block[:, :nch])
                    put(rs.resample_chunk(y) if rs else y)
                if rs:
                    put(rs.resample_chunk(np.zeros((0, nch), np.float32), last=True))
    tag = wav_format_tag(tmp)
    if tag != 1:
        os.remove(tmp)
        raise RuntimeError(f'WAV-header is geen gewone PCM (tag {tag})')
    os.replace(tmp, dst)
    bits = {'PCM_16': 16, 'PCM_24': 24, 'PCM_32': 32, 'FLOAT': 32, 'PCM_S8': 8, 'PCM_U8': 8}.get(sub, 0)
    return ('exact', '') if exact else ('omgezet', f'{sr} Hz/{bits}-bit')


# --- rekordbox.xml ---------------------------------------------------------------

def playlists(node, path=()):
    for n in node.findall('NODE'):
        if n.get('Type') == '0':
            yield from playlists(n, path + (n.get('Name', ''),))
        else:
            yield path, n


def run(a):
    out_root = os.path.abspath(a.map)
    tree = ET.parse(a.xml)
    root = tree.getroot()
    tracks = {t.get('TrackID'): t for t in root.find('COLLECTION').findall('TRACK')}
    top = root.find('PLAYLISTS/NODE')

    plan, used = {}, {}          # TrackID -> (src, dst); dst (kleine letters) -> src
    for path, pl in playlists(top) if top is not None else []:
        if a.alleen and (not path or path[0] != a.alleen):
            continue
        folder = os.path.join(out_root, safe_name(pl.get('Name', '')))
        for ref in pl.findall('TRACK'):
            tid = ref.get('Key')
            t = tracks.get(tid)
            if t is None or tid in plan or not t.get('Location', '').lower().endswith('.flac'):
                continue
            src = url_to_path(t.get('Location'))
            stem = os.path.splitext(os.path.basename(src))[0]
            dst = os.path.join(folder, stem + '.wav')
            n = 2
            while used.get(dst.lower(), src) != src:          # andere track met dezelfde naam
                dst = os.path.join(folder, f'{stem} ({n}).wav'); n += 1
            used[dst.lower()] = src
            plan[tid] = (src, dst)

    st = dict(n=len(plan), exact=0, omgezet=0, bestond=0, fout=0, ontbreekt=0, bytes=0)
    say(t='start', n=len(plan), map=out_root)
    for i, (tid, (src, dst)) in enumerate(plan.items(), 1):
        naam = os.path.basename(dst)
        try:
            if os.path.normcase(os.path.dirname(os.path.abspath(src))) == os.path.normcase(os.path.dirname(dst)):
                raise RuntimeError('doelmap is de map van het origineel')
            if not os.path.exists(src):
                st['ontbreekt'] += 1
                say(t='fout', i=i, naam=naam, msg='FLAC niet gevonden: ' + src)
                continue
            if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
                status, uitleg = 'bestond', ''
            else:
                status, uitleg = convert(src, dst)
            st[status] += 1
        except Exception as e:
            st['fout'] += 1
            say(t='fout', i=i, naam=naam, msg=str(e))
            continue
        t = tracks[tid]
        size = os.path.getsize(dst)
        st['bytes'] += size
        t.set('Location', path_to_url(dst))
        t.set('Kind', 'WAV File')
        t.set('Size', str(size))
        t.set('SampleRate', str(OUT_SR))
        t.set('BitRate', '1411')
        say(t='track', i=i, naam=naam, status=status, uitleg=uitleg)

    ET.indent(tree, '  ')
    tmp = a.uit + '.part'
    tree.write(tmp, encoding='UTF-8', xml_declaration=True)
    os.replace(tmp, a.uit)
    say(t='klaar', **st, xml=a.uit)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--xml')
    ap.add_argument('--uit')
    ap.add_argument('--map')
    ap.add_argument('--alleen', help='alleen playlists in deze map bovenaan (bijvoorbeeld PlaylistFlac)')
    a = ap.parse_args()
    if a.check:
        check()
    else:
        if not (a.xml and a.uit and a.map):
            ap.error('--xml, --uit en --map zijn nodig')
        run(a)
