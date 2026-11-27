"""PlaylistFlac - FLAC naar AIFF voor oudere CDJ's, en een rekordbox.xml die naar die AIFF's wijst.

Oudere Pioneer-spelers (van voor de CDJ-2000NXS2) spelen geen FLAC, wel AIFF en WAV.
AIFF en WAV klinken precies hetzelfde (ongecomprimeerd), maar alleen bij AIFF leest
rekordbox de cover en de tags uit het bestand; bij WAV laat rekordbox geen cover zien.
Daarom AIFF, 16-bit/44,1 kHz (speelt op elk model), met een ID3-blok (v2.4) met de
tags en de cover uit de FLAC.

- 16-bit/44,1 kHz FLAC: de samples gaan ongewijzigd over (bit voor bit gelijk).
- Andere FLAC (24 bit, 48 of 96 kHz): soxr (VHQ) naar 44,1 kHz, dan naar 16 bit met
  TPDF-dither. Posities in seconden blijven gelijk, dus cues en grid kloppen.

Leest een rekordbox.xml en de muziekbestanden, schrijft alleen in --map en naar --uit.
Elke regel op stdout is JSON, voor de voortgang in PlaylistFlac.

    naar_aiff.py --check
    naar_aiff.py --xml in.xml --uit uit.xml --map "<muziekmap>/AIFF (CDJ)" [--alleen PlaylistFlac]
"""
import argparse, json, os, re, sys
import xml.etree.ElementTree as ET
from urllib.parse import quote, unquote

sys.stdout.reconfigure(encoding='utf-8')
OUT_SR = 44100
# Vorbis-commentaar in de FLAC -> ID3-frame in de AIFF
ID3_TAGS = (('title', 'TIT2'), ('artist', 'TPE1'), ('album', 'TALB'), ('albumartist', 'TPE2'),
            ('genre', 'TCON'), ('date', 'TDRC'), ('tracknumber', 'TRCK'), ('remixer', 'TPE4'),
            ('label', 'TPUB'), ('organization', 'TPUB'), ('isrc', 'TSRC'))


def say(**m):
    print(json.dumps(m, ensure_ascii=False), flush=True)


def check():
    import numpy, soundfile as sf, soxr, mutagen  # noqa: F401
    fm = sf.available_formats()
    if 'FLAC' not in fm or 'AIFF' not in fm:
        raise SystemExit('libsndfile zonder FLAC of AIFF')
    say(t='ok', msg=f'soundfile {sf.__version__} ({sf.__libsndfile_version__}), soxr {soxr.__version__}, mutagen {mutagen.version_string}')


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

def is_plain_aiff(path):
    """FORM....AIFF (geen AIFC) met 16-bit samples."""
    with open(path, 'rb') as f:
        head = f.read(4096)
    if head[:4] != b'FORM' or head[8:12] != b'AIFF':
        return False
    i = head.find(b'COMM')
    return i >= 0 and int.from_bytes(head[i + 14:i + 16], 'big') == 16


def write_tags(src, dst):
    """Tags en cover uit de FLAC als ID3 v2.4 in de AIFF. Geeft True als er een cover is."""
    from mutagen.flac import FLAC
    from mutagen.aiff import AIFF
    from mutagen import id3
    f = FLAC(src)
    v = f.tags or {}
    a = AIFF(dst)
    if a.tags is None:
        a.add_tags()
    for key, frame in ID3_TAGS:
        val = v.get(key)
        if val and frame not in a.tags:
            a.tags.add(getattr(id3, frame)(encoding=3, text=[x for x in val if x]))
    pics = sorted(f.pictures, key=lambda p: p.type != 3)     # voorkant eerst
    if pics:
        p = pics[0]
        a.tags.add(id3.APIC(encoding=3, mime=p.mime or 'image/jpeg', type=3, desc='Cover', data=p.data))
    a.save(v2_version=4)
    return bool(pics)


def convert(src, dst):
    """Geeft (status, uitleg, cover). Schrijft eerst naar dst.part, pas na controle naar dst."""
    import numpy as np, soundfile as sf, soxr
    tmp = dst + '.part'
    with sf.SoundFile(src) as fin:
        sr, sub, ch = fin.samplerate, fin.subtype, fin.channels
        nch = min(ch, 2)
        exact = sr == OUT_SR and sub == 'PCM_16'
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with sf.SoundFile(tmp, 'w', OUT_SR, nch, 'PCM_16', format='AIFF') as fout:
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
    try:
        if not is_plain_aiff(tmp):
            raise RuntimeError('AIFF-header klopt niet')
        cover = write_tags(src, tmp)
        if not is_plain_aiff(tmp):
            raise RuntimeError('AIFF-header klopt niet na de tags')
    except Exception:
        os.remove(tmp)
        raise
    os.replace(tmp, dst)
    bits = {'PCM_16': 16, 'PCM_24': 24, 'PCM_32': 32, 'FLOAT': 32, 'PCM_S8': 8, 'PCM_U8': 8}.get(sub, 0)
    return ('exact', '', cover) if exact else ('omgezet', f'{sr} Hz/{bits}-bit', cover)


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
            dst = os.path.join(folder, stem + '.aiff')
            n = 2
            while used.get(dst.lower(), src) != src:          # andere track met dezelfde naam
                dst = os.path.join(folder, f'{stem} ({n}).aiff'); n += 1
            used[dst.lower()] = src
            plan[tid] = (src, dst)

    st = dict(n=len(plan), exact=0, omgezet=0, bestond=0, fout=0, ontbreekt=0, cover=0, bytes=0)
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
                from mutagen.aiff import AIFF
                tags = AIFF(dst).tags
                status, uitleg, cover = 'bestond', '', bool(tags and tags.getall('APIC'))
            else:
                status, uitleg, cover = convert(src, dst)
            st[status] += 1
            st['cover'] += cover
        except Exception as e:
            st['fout'] += 1
            say(t='fout', i=i, naam=naam, msg=str(e))
            continue
        t = tracks[tid]
        size = os.path.getsize(dst)
        st['bytes'] += size
        t.set('Location', path_to_url(dst))
        t.set('Kind', 'AIFF File')
        t.set('Size', str(size))
        t.set('SampleRate', str(OUT_SR))
        t.set('BitRate', '1411')
        say(t='track', i=i, naam=naam, status=status, uitleg=uitleg, cover=cover)

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
