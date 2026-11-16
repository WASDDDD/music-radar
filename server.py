#!/usr/bin/env python3
"""音乐雷达：Python 3.11+，仅标准库。"""
import argparse
import commons_provider
import concurrent.futures
import datetime as dt
import hashlib
import json
import logging
import os
import random
import re
import secrets
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DB = Path(os.environ.get('MUSICRADAR_DB', str(ROOT / 'music.sqlite3')))
UTC = dt.timezone.utc
BIZ_TZ = dt.timezone(dt.timedelta(hours=8))
LOG = logging.getLogger('music')
CHART_URL = 'https://music.163.com/api/v6/playlist/detail?id=3778678&n=100'  # 网易云音乐·热歌榜（替代 Apple Music Feed）
CHART_NAME = '网易云音乐 · 热歌榜'
POOL = concurrent.futures.ThreadPoolExecutor(max_workers=8)
SYNC_LOCK = threading.Lock()
STATE = {'lastAttempt': None, 'lastSuccess': None, 'lastError': None, 'running': False}
STATE_LOCK = threading.Lock()
CACHE = {}
CACHE_LOCK = threading.Lock()
TOKEN = secrets.token_urlsafe(32)

def now():
    return dt.datetime.now(UTC).isoformat()

def connect():
    c = sqlite3.connect(DB, timeout=15)
    c.row_factory = sqlite3.Row
    return c

def init_db():
    with connect() as c:
        c.executescript('''
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS chart_days (
          day TEXT PRIMARY KEY, collected TEXT NOT NULL, updated TEXT,
          payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS audit (
          id INTEGER PRIMARY KEY, at TEXT NOT NULL, track TEXT NOT NULL,
          allowed INTEGER NOT NULL, license TEXT, reason TEXT);
        ''')

def safe_url(url, hosts=None):
    try:
        p = urllib.parse.urlsplit(url)
        host = (p.hostname or '').lower()
        return (p.scheme == 'https' and not p.username and not p.password
                and p.port in (None, 443) and bool(host)
                and (not hosts or host in hosts))
    except (ValueError, TypeError):
        return False

def fetch_json(url, timeout=6, retries=0):
    # All network destinations are constructed by server-side providers.
    if not safe_url(url):
        raise ValueError('来源地址无效')
    attempt = 0
    while True:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'MusicRadar/1.0 (public metadata client)', 'Accept': 'application/json'})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                if not safe_url(r.url):
                    raise ValueError('来源重定向无效')
                body = r.read(5_000_001)
                if len(body) > 5_000_000:
                    raise ValueError('来源数据过大')
                return json.loads(body)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt >= retries:
                raise
            try:
                delay = min(3, max(1, float(e.headers.get('Retry-After', 1))))
            except ValueError:
                delay = 1
        except (urllib.error.URLError, TimeoutError):
            if attempt >= retries:
                raise
            delay = 1
        attempt += 1
        time.sleep(delay + random.random() / 4)

def cached(key, builder, ttl=600):
    with CACHE_LOCK:
        item = CACHE.get(key)
        if item and item[0] > time.monotonic():
            return item[1]
    value = builder()
    with CACHE_LOCK:
        if len(CACHE) > 400:
            CACHE.clear()
        CACHE[key] = (time.monotonic() + ttl, value)
    return value

def _audio_ext(u):
    path = urllib.parse.urlsplit(u or '').path
    return path.rsplit('.', 1)[-1].lower() if '.' in path else ''

def quality_fields(fmt):
    fmt = (fmt or '').lower()
    if fmt in ('flac', 'wav', 'aif', 'aiff'):
        return {'format': fmt.upper(), 'lossless': True, 'quality': '无损 ' + fmt.upper()}
    if fmt in ('m4a', 'mp4', 'aac'):
        return {'format': 'AAC', 'lossless': False, 'quality': '高音质 AAC'}
    if fmt in ('ogg', 'oga', 'opus'):
        return {'format': fmt.upper(), 'lossless': False, 'quality': '高音质 ' + fmt.upper()}
    if fmt == 'mp3':
        return {'format': 'MP3', 'lossless': False, 'quality': '高音质 MP3'}
    return {'format': fmt.upper() if fmt else '音频', 'lossless': False, 'quality': '音频'}

CCMIX_API = 'https://ccmixter.org/api/query'
CCMIX_REF = 'https://ccmixter.org/'
CCMIX_PREF = {'flac': 0, 'wav': 1, 'aif': 2, 'aiff': 2, 'ogg': 3, 'oga': 3, 'opus': 3, 'm4a': 4, 'mp3': 5}

def _ccmixter_pick(files, want=None):
    """Pick the best playable file from a ccMixter upload; FLAC/WAV (lossless) win."""
    cands = []
    for f in files or []:
        if not isinstance(f, dict):
            continue
        u = f.get('download_url') or ''
        if not safe_url(u, {'ccmixter.org'}):
            continue
        ext = _audio_ext(u)
        if ext not in CCMIX_PREF:
            continue
        cands.append((CCMIX_PREF[ext], ext, u, f.get('file_name') or u.rsplit('/', 1)[-1]))
    if not cands:
        return None
    if want:
        for c in cands:
            if c[1] == want:
                return c
    cands.sort(key=lambda x: x[0])
    return cands[0]

def ccmixter_info(upload_id):
    """Fetch and cache one ccMixter upload's file list (for search rows and the stream proxy)."""
    uid = str(upload_id)
    if not re.fullmatch(r'\d{1,12}', uid):
        raise ValueError('作品标识无效')
    def build():
        data = fetch_json(CCMIX_API + '?' + urllib.parse.urlencode({'f': 'json', 'ids': uid, 'limit': 1}),
                          timeout=6, retries=1)
        if not isinstance(data, list) or not data or not isinstance(data[0], dict):
            return None
        it = data[0]
        return {'title': it.get('upload_name'), 'page': it.get('file_page_url'),
                'license_name': it.get('license_name'), 'license_url': it.get('license_url'),
                'files': it.get('files') or []}
    return cached(('ccmix', uid), build, ttl=900)

def search_ccmixter(q, kind):
    if kind != 'track':
        return []
    data = fetch_json(CCMIX_API + '?' + urllib.parse.urlencode({'f': 'json', 'search': q, 'limit': 8}),
                      timeout=6, retries=1)
    if not isinstance(data, list):
        return []
    rows = []
    for it in data:
        if not isinstance(it, dict):
            continue
        uid = it.get('upload_id')
        pick = _ccmixter_pick(it.get('files'))
        if not uid or not pick:
            continue
        _, ext, _url, _fname = pick
        qf = quality_fields(ext)
        lic = it.get('license_name') or 'Creative Commons'
        lurl = it.get('license_url') or ''
        rows.append({'id': 'ccmixter:' + str(uid), 'title': it.get('upload_name') or '未命名作品',
                     'artist': it.get('user_real_name') or it.get('user_name') or '未知创作人', 'album': '',
                     'cover': '', 'url': it.get('file_page_url') or CCMIX_REF,
                     'preview': '/api/stream?id=ccmixter:' + str(uid), 'source': 'ccMixter',
                     'downloadable': True, 'license': lic + (' · ' + lurl if lurl else ''),
                     'format': qf['format'], 'lossless': qf['lossless'], 'quality': qf['quality'],
                     '_downloadUrl': pick[2], '_licenseUrl': lurl})
    return rows

NETEASE_SEARCH = 'https://music.163.com/api/cloudsearch/pc'
NETEASE_REF = 'https://music.163.com/'
METING_HOSTS = ('https://api.qijieya.cn/meting/', 'https://api.injahow.cn/meting/')

def _netease_fetch(url):
    if not safe_url(url):
        raise ValueError('来源地址无效')
    req = urllib.request.Request(url, headers={
        'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36',
        'Referer': NETEASE_REF, 'Accept': 'application/json', 'Cookie': 'appver=2.0.2'})
    with urllib.request.urlopen(req, timeout=8) as r:
        body = r.read(2_000_000)
    return json.loads(body)

def search_netease(q, kind):
    if kind != 'track':
        return []
    url = NETEASE_SEARCH + '?' + urllib.parse.urlencode({'s': q, 'type': 1, 'offset': 0, 'limit': 15})
    data = _netease_fetch(url)
    songs = (data.get('result') or {}).get('songs') or []
    rows = []
    for song in songs:
        sid = song.get('id')
        if not sid:
            continue
        artists = ' / '.join(a.get('name', '') for a in (song.get('ar') or []) if a.get('name')) or '未知艺人'
        album = (song.get('al') or {}).get('name') or ''
        pic = (song.get('al') or {}).get('picUrl') or ''
        if pic.startswith('http://'):
            pic = 'https://' + pic[7:]
        rows.append({'id': 'netease:' + str(sid), 'title': song.get('name') or '未命名',
                     'artist': artists, 'album': album, 'cover': pic,
                     'url': 'https://music.163.com/#/song?id=' + str(sid),
                     'preview': '/api/stream?id=netease:' + str(sid),
                     'source': '网易云音乐 · FLAC', 'downloadable': True,
                     'license': '第三方无损解析 · 仅供个人试听，请支持正版',
                     'format': 'FLAC', 'lossless': True, 'quality': '无损 FLAC'})
    if rows:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
            flags = list(ex.map(lambda r: _netease_flac_ok(r['id'].split(':', 1)[1]), rows))
        rows = [r for r, ok in zip(rows, flags) if ok]
    return rows

def _meting_url(host, sid, br='999000'):
    return host + '?' + urllib.parse.urlencode({'server': 'netease', 'type': 'url', 'id': str(sid), 'br': br})

def _netease_flac_ok(sid):
    """Confirm a track really resolves to a FLAC stream (so we never advertise lossy as lossless)."""
    def build():
        for host in METING_HOSTS:
            try:
                req = urllib.request.Request(_meting_url(host, sid),
                                             headers={'User-Agent': 'Mozilla/5.0', 'Range': 'bytes=0-3'})
                with urllib.request.urlopen(req, timeout=5) as r:
                    head = r.read(4)
                return head[:4] == b'fLaC'
            except Exception:
                continue
        return False
    return cached(('nflac', str(sid)), build, ttl=900)

ONEMUSIC_BASE = 'https://backend.1music.cc/'
ONEMUSIC_REF = 'https://1music.cc/zh-CN'
ONEMUSIC_META = {}

def _1music_call(path, payload=None, timeout=20):
    base = ONEMUSIC_BASE
    if not safe_url(base):
        raise ValueError('来源地址无效')
    url = base + path
    data = json.dumps(payload).encode() if payload is not None else None
    hdrs = {'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36',
            'Accept': 'application/json', 'Origin': 'https://1music.cc',
            'Referer': ONEMUSIC_REF, 'Content-Type': 'application/json'}
    req = urllib.request.Request(url, data=data, headers=hdrs,
                                 method=('POST' if data is not None else 'GET'))
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read(4_000_000)
    return json.loads(body)

def _1music_list():
    """Public rotating list from backend.1music.cc (search API is captcha-gated)."""
    def build():
        data = _1music_call('', None)
        lst = data.get('music_list') or []
        for it in lst:
            h = it.get('hash')
            if h and it.get('song_hash'):
                ONEMUSIC_META[h] = it
        return lst
    return cached(('1music_list',), build, ttl=60)

def search_1music(q, kind):
    items = _1music_list()
    ql = (q or '').strip().lower()
    rows = []
    for it in items:
        h = it.get('hash')
        if not h:
            continue
        title = it.get('title') or '未命名'
        artist = it.get('artist') or ''
        album = it.get('album') or ''
        if ql and ql not in (title + ' ' + artist + ' ' + album).lower():
            continue
        rows.append({'id': '1music:' + h, 'title': title, 'artist': artist or '未知艺人',
                     'album': album, 'cover': it.get('thumbnail') or '',
                     'url': 'https://1music.cc/zh-CN',
                     'preview': '/api/stream?id=1music:' + h,
                     'source': '1Music · 有损(WebM)', 'downloadable': True,
                     'license': '第三方站点直链 · 仅供个人试听',
                     'format': 'WebM', 'lossless': False, 'quality': 'WebM/Opus 有损'})
    return rows

def _1music_resolve(h):
    meta = ONEMUSIC_META.get(h)
    if not meta:
        for it in _1music_list():
            if it.get('hash') == h:
                meta = it
                break
    if not meta:
        raise ValueError('曲目不存在')
    payload = {'title': meta.get('title', ''), 'album': meta.get('album', ''),
               'artist': meta.get('artist', ''), 'videoId': meta.get('videoId', ''),
               'song_hash': meta.get('song_hash', ''), 'exp': meta.get('exp', 0),
               'request_format': 'webm', 'thumbnail': meta.get('thumbnail', '')}
    data = _1music_call('download/', payload, timeout=30)
    url = data.get('download_url') or ''
    if not url or not safe_url(url):
        raise ValueError('未取得下载直链')
    return url, meta

def normalize_apple(row):
    return {'id': 'itunes:' + str(row['trackId']), 'title': row.get('trackName', ''),
            'artist': row.get('artistName', ''), 'album': row.get('collectionName', ''),
            'cover': row.get('artworkUrl100', ''), 'url': row.get('trackViewUrl', ''),
            'preview': row.get('previewUrl', ''), 'source': 'Apple / iTunes',
            'downloadable': False, 'license': '官方试听 / 平台播放，不提供音频下载',
            'format': 'AAC', 'lossless': False, 'quality': '官方试听 · 完整无损需平台会员'}

def _itunes_storefront(q, kind, country):
    attr = {'artist': 'artistTerm', 'album': 'albumTerm', 'track': 'songTerm'}[kind]
    params = urllib.parse.urlencode({'term': q, 'entity': 'song', 'attribute': attr,
                                     'country': country, 'limit': 30, 'lang': 'zh_tw'})
    data = fetch_json('https://itunes.apple.com/search?' + params, timeout=5)
    return [normalize_apple(x) for x in data.get('results', []) if x.get('trackId')]

def search_itunes(q, kind):
    # Different storefronts carry different catalogs; query them concurrently so
    # latency stays near the fastest one instead of the sum of three round trips.
    futures = [POOL.submit(_itunes_storefront, q, kind, c) for c in ('tw', 'hk', 'cn')]
    rows, seen = [], set()
    for f in futures:
        try:
            found = f.result(timeout=5)
        except Exception:
            continue
        for r in found:
            key = (r['title'], r['artist'], r['album'])
            if key not in seen:
                seen.add(key)
                rows.append(r)
        if len(rows) >= 35:
            break
    return rows[:35]

CC_PATTERN = re.compile(r'^https?://creativecommons\.org/(?:licenses/(?:by|by-sa|by-nc|by-nc-sa|by-nd|by-nc-nd)/[1-4]\.0|publicdomain/(?:zero/1\.0|mark/1\.0))/?(?:[?#].*)?$', re.I)

def licenses_of(meta):
    values = meta.get('licenseurl', [])
    if isinstance(values, str):
        values = [values]
    return [v for v in values if isinstance(v, str) and CC_PATTERN.fullmatch(v)]

def is_restricted(metadata):
    flags = ('is_dark', 'access-restricted-item', 'is_access_restricted', 'restricted')
    return any(str(metadata.get(k, '')).lower() in ('true', '1', 'yes') for k in flags)

def as_text(v):
    return '; '.join(str(x) for x in v) if isinstance(v, list) else str(v or '')

def archive_detail(identifier):
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,200}', identifier):
        raise ValueError('条目标识无效')
    return fetch_json('https://archive.org/metadata/' + urllib.parse.quote(identifier, safe=''))

def choose_archive_file(data):
    meta = data.get('metadata', {})
    if is_restricted(meta) or not licenses_of(meta):
        return None
    pref = {'.flac': 0, '.wav': 1, '.m4a': 2, '.ogg': 3, '.mp3': 4}
    candidates = []
    for f in data.get('files', []):
        name = f.get('name', '')
        ext = ('.' + name.rsplit('.', 1)[-1].lower()) if '.' in name else ''
        if (ext in pref
                and not is_restricted(f) and str(f.get('private', '')).lower() not in ('true', '1')
                and isinstance(name, str) and not name.startswith('/') and '..' not in name.split('/')):
            candidates.append((pref[ext], name, f))
    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0])
    return candidates[0][2]

def archive_row(identifier, data):
    meta = data.get('metadata', {})
    lics = licenses_of(meta)
    selected = choose_archive_file(data)
    preview = ''
    q = quality_fields('')
    if selected:
        name = selected.get('name', '')
        url = ('https://archive.org/download/' + urllib.parse.quote(identifier, safe='') +
               '/' + urllib.parse.quote(name, safe=''))
        if safe_url(url, {'archive.org'}):
            preview = url
        q = quality_fields(_audio_ext(name))
    return {'id': 'archive:' + identifier, 'title': as_text(meta.get('title', identifier)),
            'artist': as_text(meta.get('creator', '未知创作者')), 'album': as_text(meta.get('album', '')),
            'cover': 'https://archive.org/services/img/' + urllib.parse.quote(identifier, safe=''),
            'url': 'https://archive.org/details/' + urllib.parse.quote(identifier, safe=''),
            'preview': preview, 'source': 'Internet Archive', 'downloadable': bool(selected),
            'license': lics[0] if selected else '授权未核实，请查看来源', **q}

def search_archive(q, kind):
    # Escape query syntax; user input is never interpreted as an Archive query.
    term = re.sub(r'[^\w\s\u3400-\u9fff-]', ' ', q, flags=re.UNICODE).strip()
    if not term:
        return []
    field = {'track': 'title', 'artist': 'creator', 'album': 'album'}[kind]
    query = f'mediatype:audio AND {field}:"{term}"'
    params = urllib.parse.urlencode({'q': query, 'output': 'json', 'rows': 12, 'page': 1,
                                     'fl[]': 'identifier'})
    result = fetch_json('https://archive.org/advancedsearch.php?' + params, timeout=8)
    identifiers = [x['identifier'] for x in result.get('response', {}).get('docs', []) if x.get('identifier')]
    # A bounded local pool prevents detail lookups from blocking other provider searches.
    def one(ident):
        try:
            data = cached(('archive-meta', ident), lambda: archive_detail(ident), 1800)
            return archive_row(ident, data)
        except Exception:
            return {'id': 'archive:' + ident, 'title': ident, 'artist': '详情暂不可用', 'album': '',
                    'cover': '', 'url': 'https://archive.org/details/' + urllib.parse.quote(ident, safe=''),
                    'preview': '', 'source': 'Internet Archive', 'downloadable': False, 'license': '待核实'}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as p:
        return list(p.map(one, identifiers))

AUDIUS_APP = 'MusicRadar'

def audius_stream(track_id):
    return 'https://api.audius.co/v1/tracks/' + urllib.parse.quote(track_id, safe='') + '/stream?app_name=' + AUDIUS_APP

def search_audius(q, kind):
    params = urllib.parse.urlencode({'query': q, 'limit': 25, 'app_name': AUDIUS_APP})
    data = fetch_json('https://api.audius.co/v1/tracks/search?' + params, timeout=6)
    rows = []
    for t in data.get('data', []):
        if not t.get('id') or not t.get('title'):
            continue
        # Only publicly streamable, non-gated tracks can actually be played.
        if not t.get('is_streamable') or t.get('is_stream_gated'):
            continue
        user = t.get('user') or {}
        permalink = t.get('permalink') or ''
        url = 'https://audius.co' + permalink if isinstance(permalink, str) and permalink.startswith('/') else 'https://audius.co'
        rows.append({'id': 'audius:' + str(t['id']), 'title': t['title'],
                     'artist': user.get('name', '未知艺人'), 'album': '',
                     'cover': (t.get('artwork') or {}).get('150x150', ''),
                     'url': url, 'preview': audius_stream(t['id']), 'source': 'Audius',
                     'downloadable': bool(t.get('is_downloadable')) and not t.get('is_download_gated'),
                     'license': t.get('license') or '平台流媒体',
                     'format': 'MP3', 'lossless': False, 'quality': '完整 MP3（有损）'})
    return rows

MB_ESCAPE = re.compile(r'([+\-&|!(){}\[\]^"~*?:\\/])')
# MusicBrainz throttles to ~1 request/second; pace our own calls so concurrent
# searches do not trip self-inflicted 503s.
MB_LOCK = threading.Lock()
MB_LAST = [0.0]

def _mb_pace():
    with MB_LOCK:
        wait = 1.1 - (time.time() - MB_LAST[0])
        if wait > 0:
            time.sleep(wait)
        MB_LAST[0] = time.time()

def search_musicbrainz(q, kind):
    field = {'track': 'recording', 'artist': 'artist', 'album': 'release'}[kind]
    query = field + ':' + MB_ESCAPE.sub(r'\\\1', q)
    params = urllib.parse.urlencode({'query': query, 'fmt': 'json', 'limit': 15})
    _mb_pace()
    data = fetch_json('https://musicbrainz.org/ws/2/recording/?' + params, timeout=6, retries=2)
    rows = []
    for r in data.get('recordings', []):
        if not r.get('id') or not r.get('title'):
            continue
        artists = ' / '.join(a['name'] for a in r.get('artist-credit', [])
                             if isinstance(a, dict) and a.get('name')) or '未知艺人'
        releases = r.get('releases') or []
        album = releases[0].get('title', '') if releases and isinstance(releases[0], dict) else ''
        rows.append({'id': 'musicbrainz:' + r['id'], 'title': r['title'], 'artist': artists,
                     'album': album, 'cover': '', 'url': 'https://musicbrainz.org/recording/' + r['id'],
                     'preview': '', 'source': 'MusicBrainz', 'downloadable': False,
                     'license': '目录元数据 · 播放请到官方平台',
                     'format': '—', 'lossless': False, 'quality': '仅目录'})
    return rows

def error_text(exc):
    if isinstance(exc, urllib.error.HTTPError):
        return f'来源返回 HTTP {exc.code}'
    return '来源暂不可达或响应无效，请稍后重试'

def search(q, kind, source, downloadable, lossless=False):
    providers = {'itunes': search_itunes, 'audius': search_audius,
                 'musicbrainz': search_musicbrainz, 'archive': search_archive,
                 'ccmixter': search_ccmixter, 'netease': search_netease,
                 '1music': search_1music,
                 'commons': lambda q, kind: commons_provider.search(fetch_json, safe_url, licenses_of, q, kind)}
    # Default mix: the fast, responsive sources only. Archive is slow/flaky and
    # is offered on explicit selection so it never drags down ordinary searches.
    # 只保留能真无损播放的开放源；试听/有损/仅目录源已按需求移除。
    default = ('netease', 'commons', 'ccmixter')
    names = default if source == 'all' else (source,)
    if downloadable:
        names = tuple(n for n in names if n in ('audius', 'commons', 'archive', 'ccmixter', 'netease', '1music'))
        if not names:
            return {'items': [], 'sources': [{'name': source, 'status': 'success', 'count': 0,
                                              'message': '此来源不提供授权下载'}]}
    futures = {POOL.submit(cached, ('search', n, q, kind), (lambda fn=providers[n]: lambda: fn(q, kind))()): n
               for n in names}
    items, statuses, pending = [], [], set(futures)
    deadline = time.monotonic() + 6.5
    while pending:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        done, pending = concurrent.futures.wait(pending, timeout=left,
                                                return_when=concurrent.futures.FIRST_COMPLETED)
        for f in done:
            name = futures[f]
            try:
                rows = f.result()
                items.extend(x for x in rows if not downloadable or x['downloadable'])
                statuses.append({'name': name, 'status': 'success', 'count': len(rows)})
            except Exception as e:
                LOG.warning('search source=%s error=%s', name, type(e).__name__)
                statuses.append({'name': name, 'status': 'error', 'error': error_text(e)})
    for f in pending:
        statuses.append({'name': futures[f], 'status': 'timeout', 'error': '响应超时，已略过'})
    order = {n: i for i, n in enumerate(names)}
    statuses.sort(key=lambda s: order.get(s['name'], 99))
    # 应用核心只承载无损音源；1music 为显式选择的有损外部源，此时不做无损过滤。
    if source != '1music':
        items = [x for x in items if x.get('lossless')]
    # Lossless-capable results float to the top so high-quality playback is one tap away.
    items.sort(key=lambda x: (not x.get('lossless'), x.get('source', '')))
    return {'items': items, 'sources': statuses}

def sync_chart():
    if not SYNC_LOCK.acquire(blocking=False):
        return False
    with STATE_LOCK:
        STATE.update(running=True, lastAttempt=now())
    try:
        data = _netease_fetch(CHART_URL)
        pl = data.get('playlist') or {}
        raw = pl.get('tracks') or []
        if not isinstance(raw, list) or not raw:
            raise ValueError('来源未返回榜单，保留旧数据')
        items = []
        for rank, row in enumerate(raw, 1):
            if not row.get('id') or not row.get('name'):
                raise ValueError('榜单字段缺失')
            artist = ' / '.join(a.get('name', '') for a in (row.get('ar') or []) if a.get('name'))
            al = row.get('al') or {}
            sid = str(row['id'])
            items.append({'id': 'netease:' + sid, 'title': row['name'],
                          'artist': artist, 'album': al.get('name', ''),
                          'cover': al.get('picUrl', ''), 'url': 'https://music.163.com/song?id=' + sid,
                          'preview': '/api/stream?id=netease:' + sid,
                          'source': CHART_NAME, 'downloadable': True,
                          'license': '第三方解析 · 个人使用', 'lossless': True,
                          'format': 'FLAC', 'quality': '无损 FLAC',
                          'rank': rank, 'score': len(raw) - rank + 1})
        stamp = now()
        day = dt.datetime.now(BIZ_TZ).date().isoformat()
        with connect() as c:
            c.execute('INSERT INTO chart_days VALUES (?, ?, ?, ?) ON CONFLICT(day) DO UPDATE SET collected=excluded.collected, updated=excluded.updated, payload=excluded.payload',
                      (day, stamp, stamp, json.dumps(items, ensure_ascii=False)))
        with STATE_LOCK:
            STATE.update(lastSuccess=stamp, lastError=None)
        LOG.info('chart sync success items=%s day=%s', len(items), day)
        return True
    except Exception as e:
        with STATE_LOCK:
            STATE['lastError'] = error_text(e)
        LOG.warning('chart sync failed: %s', type(e).__name__)
        return False
    finally:
        with STATE_LOCK:
            STATE['running'] = False
        SYNC_LOCK.release()

def charts(period):
    days = {'daily': 1, 'weekly': 7, 'monthly': 30}[period]
    today = dt.datetime.now(BIZ_TZ).date()
    with connect() as c:
        latest = c.execute('SELECT * FROM chart_days ORDER BY day DESC LIMIT 1').fetchone()
        rows = c.execute('SELECT * FROM chart_days WHERE day>=? AND day<=? ORDER BY day',
                         ((today - dt.timedelta(days=days - 1)).isoformat(), today.isoformat())).fetchall()
    with STATE_LOCK:
        state = dict(STATE)
    base = {'period': period, 'expectedDays': days, 'coverageDays': len(rows),
            'updatedAt': latest['updated'] if latest else None, 'collectedAt': latest['collected'] if latest else None,
            'source': CHART_NAME, 'error': state['lastError'],
            'stale': not latest or latest['day'] != today.isoformat() or
            (dt.datetime.now(UTC) - dt.datetime.fromisoformat(latest['collected'])).total_seconds() > 10800,
            'method': '日榜为网易云音乐热歌榜的当日最新快照；周/月榜为本站最近7/30天每日最后一次快照的排名积分累计，缺席记0；不是平台官方周/月榜。',
            'label': {'daily': '网易云热歌榜·今日快照', 'weekly': '网易云热歌榜·近7天热度榜', 'monthly': '网易云热歌榜·近30天热度榜'}[period]}
    if period == 'daily':
        base['items'] = json.loads(latest['payload']) if latest else []
        base['message'] = '显示最近成功快照' if base['stale'] else '网易云音乐热歌榜当日最新快照'
    else:
        totals = {}
        for row in rows:
            day_items = json.loads(row['payload'])
            for item in day_items:
                score = (len(day_items) - item['rank'] + 1) / len(day_items) * 100
                entry = totals.setdefault(item['id'], {'item': item, 'score': 0.0, 'count': 0})
                entry.update(item=item, score=entry['score'] + score, count=entry['count'] + 1)
        ordered = sorted(totals.values(), key=lambda x: (-x['score'], x['item']['id']))[:100]
        base['items'] = [dict(e['item'], rank=i, score=round(e['score'], 2), appearances=e['count'])
                         for i, e in enumerate(ordered, 1)]
        base['message'] = f'已积累 {len(rows)}/{days} 天真实数据。' + ('历史不足，持续运行后自动补齐。' if len(rows) < days else '滚动周期统计。')
    return base

def authorize_download(track_id):
    allowed, license_url, reason = False, None, '此来源不提供下载授权'
    result = None
    try:
        if track_id.startswith('commons:'):
            title = track_id.split(':', 1)[1]
            if not title.startswith('File:') or len(title) > 220:
                raise PermissionError('文件标识无效')
            pages = commons_provider.details(fetch_json, title)
            row = commons_provider.normalize(pages[0], safe_url, licenses_of) if pages else {}
            if not row.get('downloadable'):
                raise PermissionError('文件当前未明确允许下载')
            license_url = row['_licenseUrl']
            allowed, reason = True, 'Commons 文件页开放许可，下载后须遵守署名等适用条件'
            return {'url': row['_downloadUrl'], 'license': license_url, 'title': row['title'], 'notice': reason}
        if track_id.startswith('audius:'):
            tid = track_id.split(':', 1)[1]
            if not re.fullmatch(r'[A-Za-z0-9]{1,30}', tid):
                raise PermissionError('音频标识无效')
            data = fetch_json('https://api.audius.co/v1/tracks/' + urllib.parse.quote(tid, safe='') +
                              '?app_name=' + AUDIUS_APP, timeout=6)
            t = data.get('data') or {}
            if not (t.get('is_downloadable') and not t.get('is_download_gated')):
                raise PermissionError('该曲目未开启下载授权')
            url = ('https://api.audius.co/v1/tracks/' + urllib.parse.quote(tid, safe='') +
                   '/download?app_name=' + AUDIUS_APP)
            license_url = t.get('license') or '创作者授权下载'
            allowed, reason = True, '创作者在 Audius 开启下载；请遵守平台与创作者条款'
            return {'url': url, 'license': license_url, 'title': as_text(t.get('title', tid)),
                    'notice': reason}
        if track_id.startswith('netease:'):
            sid = track_id.split(':', 1)[1]
            if not re.fullmatch(r'\d{1,12}', sid):
                raise PermissionError('歌曲标识无效')
            allowed, reason = True, '第三方无损解析，仅供个人试听与离线自用；请支持正版'
            return {'url': '/api/stream?id=netease:' + urllib.parse.quote(sid) + '&dl=1',
                    'license': '个人使用（第三方解析）', 'title': '网易云歌曲 ' + sid, 'notice': reason}
        if track_id.startswith('ccmixter:'):
            uid = track_id.split(':', 1)[1]
            info = ccmixter_info(uid)
            if not info or not _ccmixter_pick(info.get('files')):
                raise PermissionError('该作品暂无可下载音频')
            lic = info.get('license_name') or 'Creative Commons'
            lurl = info.get('license_url') or ''
            allowed, reason = True, 'ccMixter 开放许可作品；下载后请遵守署名/非商业等适用条款'
            return {'url': '/api/stream?id=ccmixter:' + urllib.parse.quote(uid) + '&dl=1',
                    'license': lic + (' · ' + lurl if lurl else ''), 'title': as_text(info.get('title') or uid),
                    'notice': reason}
        if track_id.startswith('1music:'):
            h = track_id.split(':', 1)[1]
            if not re.fullmatch(r'[a-f0-9]{16,64}', h):
                raise PermissionError('曲目标识无效')
            allowed, reason = True, '第三方站点直链（WebM/Opus 有损），仅供个人试听与自用'
            return {'url': '/api/stream?id=1music:' + urllib.parse.quote(h) + '&dl=1',
                    'license': '个人使用（第三方直链）', 'title': '1Music ' + h[:8], 'notice': reason}
        if not track_id.startswith('archive:'):
            raise PermissionError(reason)
        identifier = track_id.split(':', 1)[1]
        # Bypass cache: verify metadata and access flags again on every click.
        data = archive_detail(identifier)
        file = choose_archive_file(data)
        if not file:
            raise PermissionError('未找到明确开放许可证下的公开音频文件')
        license_url = licenses_of(data['metadata'])[0]
        url = 'https://archive.org/download/' + urllib.parse.quote(identifier, safe='') + '/' + urllib.parse.quote(file['name'], safe='')
        if not safe_url(url, {'archive.org'}):
            raise PermissionError('下载地址未通过校验')
        allowed, reason = True, '来源当前声明为开放许可；请保留署名并遵守非商业/禁止演绎等适用条件'
        result = {'url': url, 'license': license_url, 'title': as_text(data['metadata'].get('title', identifier)), 'notice': reason}
        return result
    finally:
        with connect() as c:
            c.execute('INSERT INTO audit(at, track, allowed, license, reason) VALUES (?, ?, ?, ?, ?)',
                      (now(), track_id[:240], int(allowed), license_url, reason))

def scheduler(stop):
    delay = 0
    failures = 0
    while not stop.wait(delay):
        success = sync_chart()
        failures = 0 if success else failures + 1
        # 2-hour refresh; 5m/30m/2h retries with jitter on failures.
        delay = 7200 if success else (300, 1800, 7200)[min(failures - 1, 2)] + random.randint(0, 30)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        LOG.info('%s %s', self.client_address[0], fmt % args)

    def send_json(self, status, data):
        raw = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(raw)

    def _open_media(self, url, referer=None):
        if not safe_url(url):
            raise ValueError('audio url invalid')
        hdrs = {'User-Agent': 'MusicRadar/1.0', 'Accept': '*/*'}
        if referer:
            hdrs['Referer'] = referer
        rng = self.headers.get('Range')
        if rng:
            hdrs['Range'] = rng
        return urllib.request.urlopen(urllib.request.Request(url, headers=hdrs), timeout=30)

    def _relay(self, r, dl, filename):
        try:
            self.send_response(r.status if r.status in (200, 206) else 200)
            self.send_header('Content-Type', r.headers.get('Content-Type') or 'application/octet-stream')
            for h in ('Content-Length', 'Content-Range'):
                v = r.headers.get(h)
                if v:
                    self.send_header(h, v)
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Cache-Control', 'no-store')
            if dl:
                self.send_header('Content-Disposition', 'attachment; filename="%s"' % filename)
            self.end_headers()
            while True:
                chunk = r.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            r.close()

    def proxy_audio(self, url, dl=False):
        try:
            r = self._open_media(url, referer=CCMIX_REF)
        except urllib.error.HTTPError as e:
            return self.send_json(502, {'error': '来源返回 HTTP %s' % e.code})
        except Exception:
            return self.send_json(502, {'error': '来源暂不可达'})
        ext = _audio_ext(url) or 'audio'
        return self._relay(r, dl, 'ccmixter.' + ext)

    def proxy_netease(self, sid, dl=False):
        if not re.fullmatch(r'\d{1,12}', str(sid)):
            return self.send_json(400, {'error': '歌曲标识无效'})
        last = '来源暂不可达'
        for host in METING_HOSTS:
            try:
                r = self._open_media(_meting_url(host, sid), referer=NETEASE_REF)
            except urllib.error.HTTPError as e:
                last = '来源返回 HTTP %s' % e.code
                continue
            except Exception:
                last = '来源暂不可达'
                continue
            return self._relay(r, dl, 'netease-%s.flac' % sid)
        return self.send_json(502, {'error': last})

    def proxy_1music(self, h, dl=False):
        if not re.fullmatch(r'[a-f0-9]{16,64}', h or ''):
            return self.send_json(400, {'error': '曲目标识无效'})
        try:
            url, meta = _1music_resolve(h)
        except ValueError as e:
            return self.send_json(404, {'error': str(e)})
        except urllib.error.HTTPError as e:
            return self.send_json(502, {'error': '来源返回 HTTP %s' % e.code})
        except Exception:
            return self.send_json(502, {'error': '来源暂不可达'})
        try:
            r = self._open_media(url, referer='https://1music.cc/')
        except urllib.error.HTTPError as e:
            return self.send_json(502, {'error': '来源返回 HTTP %s' % e.code})
        except Exception:
            return self.send_json(502, {'error': '来源暂不可达'})
        name = (str(meta.get('artist', '')) + ' - ' + str(meta.get('title', ''))).strip(' -') or ('1music-' + h)
        name = re.sub(r'[\\/:*?"<>|]+', '_', name)[:80] + '.webm'
        return self._relay(r, dl, name)

    def do_GET(self):
        p = urllib.parse.urlsplit(self.path)
        params = urllib.parse.parse_qs(p.query)
        def arg(k, default=''):
            return params.get(k, [default])[0]
        try:
            if p.path == '/api/session':
                return self.send_json(200, {'token': TOKEN})
            if p.path == '/api/search':
                q, kind, source = arg('q').strip(), arg('type', 'track'), arg('source', 'all')
                if not 1 <= len(q) <= 160 or kind not in ('track', 'artist', 'album') or source not in ('all', 'netease', 'commons', 'ccmixter', 'archive', '1music'):
                    return self.send_json(400, {'error': '搜索条件无效'})
                return self.send_json(200, search(q, kind, source, arg('downloadable') == '1', arg('lossless') == '1'))
            if p.path == '/api/stream':
                tid = arg('id')
                if tid.startswith('netease:'):
                    return self.proxy_netease(tid.split(':', 1)[1], dl=arg('dl') == '1')
                if tid.startswith('1music:'):
                    return self.proxy_1music(tid.split(':', 1)[1], dl=arg('dl') == '1')
                if not tid.startswith('ccmixter:'):
                    return self.send_json(400, {'error': '不支持的音源'})
                try:
                    info = ccmixter_info(tid.split(':', 1)[1])
                except ValueError:
                    return self.send_json(400, {'error': '作品标识无效'})
                except Exception:
                    return self.send_json(502, {'error': '来源暂不可达'})
                pick = _ccmixter_pick((info or {}).get('files') or [])
                if not info or not pick:
                    return self.send_json(404, {'error': '未找到可播放音频'})
                return self.proxy_audio(pick[2], dl=arg('dl') == '1')
            if p.path == '/api/charts':
                period = arg('period', 'daily')
                if period not in ('daily', 'weekly', 'monthly'):
                    return self.send_json(400, {'error': '榜单周期无效'})
                return self.send_json(200, charts(period))
            if p.path == '/api/status':
                with STATE_LOCK:
                    state = dict(STATE)
                return self.send_json(200, {'sources': [
                    {'name': CHART_NAME, 'capabilities': ['中文热歌榜榜单数据', '日/周/月热度榜']},
                    {'name': '网易云音乐 · FLAC', 'capabilities': ['中文歌曲搜索', '无损 FLAC 在线播放', '第三方解析']},
                    {'name': 'Wikimedia Commons', 'capabilities': ['开放音频搜索', '无损在线播放', '逐文件许可复核下载']},
                    {'name': 'Internet Archive', 'capabilities': ['开放音频检索', '逐条授权检查', '公开原文件下载']},
                    {'name': 'ccMixter', 'capabilities': ['CC 授权创作音乐', 'FLAC/WAV 无损在线播放', '开放下载']},
                    {'name': '1Music（有损）', 'capabilities': ['第三方站点直链', 'WebM/Opus 有损在线播放', '公开列表（搜索需验证码）']}],
                    'scheduler': dict(state, intervalSeconds=7200, timezone='Asia/Shanghai'),
                    'notice': '来源可达性与地区有关；官方平台播放仍遵循平台自身的地区、账号及订阅要求。'})
            if p.path in ('/manifest.webmanifest', '/manifest.json'):
                raw = (ROOT / 'manifest.webmanifest').read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'application/manifest+json; charset=utf-8')
                self.send_header('Content-Length', str(len(raw)))
                self.send_header('Cache-Control', 'public, max-age=3600')
                self.end_headers()
                self.wfile.write(raw)
                return
            if p.path in ('/icon.svg', '/favicon.ico'):
                raw = (ROOT / 'icon.svg').read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'image/svg+xml')
                self.send_header('Content-Length', str(len(raw)))
                self.send_header('Cache-Control', 'public, max-age=86400')
                self.end_headers()
                self.wfile.write(raw)
                return
            if p.path in ('/', '/index.html'):
                raw = (ROOT / 'index.html').read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(raw)))
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.send_header('Referrer-Policy', 'no-referrer')
                self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' https: data:; media-src 'self' https:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
                self.end_headers()
                self.wfile.write(raw)
                return
            self.send_json(404, {'error': '未找到页面'})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            LOG.exception('request failed')
            self.send_json(502, {'error': error_text(e)})

    def do_POST(self):
        # Same-origin token prevents drive-by requests against the local service.
        if self.headers.get('X-Music-Token') != TOKEN:
            return self.send_json(403, {'error': '页面会话已失效，请刷新页面'})
        origin = self.headers.get('Origin')
        if origin and urllib.parse.urlsplit(origin).netloc != self.headers.get('Host'):
            return self.send_json(403, {'error': '只允许同源操作'})
        path = urllib.parse.urlsplit(self.path).path
        try:
            if path == '/api/refresh':
                with STATE_LOCK:
                    last = STATE['lastAttempt']
                    running = STATE['running']
                if running or (last and (dt.datetime.now(UTC) - dt.datetime.fromisoformat(last)).total_seconds() < 60):
                    return self.send_json(202, {'status': 'running_or_recent', 'message': '更新进行中或刚更新，请稍后查看'})
                POOL.submit(sync_chart)
                return self.send_json(202, {'status': 'queued', 'message': '更新已提交，请稍后刷新榜单'})
            if path == '/api/download':
                size = int(self.headers.get('Content-Length', '0'))
                if size < 1 or size > 4096:
                    return self.send_json(400, {'error': '请求大小无效'})
                body = json.loads(self.rfile.read(size))
                track_id = body.get('id')
                if not isinstance(track_id, str) or len(track_id) > 240:
                    return self.send_json(400, {'error': '歌曲标识无效'})
                return self.send_json(200, authorize_download(track_id))
            self.send_json(404, {'error': '未知接口'})
        except PermissionError as e:
            self.send_json(403, {'error': str(e)})
        except (ValueError, TypeError, AttributeError):
            self.send_json(400, {'error': '请求格式无效'})
        except Exception as e:
            self.send_json(502, {'error': error_text(e)})

def main():
    parser = argparse.ArgumentParser(description='音乐雷达中文 Web 服务')
    parser.add_argument('--host', default=os.environ.get('HOST', '127.0.0.1'))
    parser.add_argument('--port', type=int, default=int(os.environ.get('PORT', '8765')))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    init_db()
    stop = threading.Event()
    threading.Thread(target=scheduler, args=(stop,), daemon=True, name='chart-scheduler').start()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    LOG.info('音乐雷达 http://%s:%s', args.host, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.server_close()

if __name__ == '__main__':
    main()
