"""Wikimedia Commons 开放音频适配器：官方 API，逐文件许可证复核。"""
import html
import re
import urllib.parse

API = 'https://commons.wikimedia.org/w/api.php'

def clean(value):
    return html.unescape(re.sub(r'<[^>]*>', '', value or '')).strip()[:1200]

def details(fetch, title):
    params = {'action': 'query', 'format': 'json', 'titles': title,
              'prop': 'imageinfo', 'iiprop': 'url|extmetadata|mime'}
    data = fetch(API + '?' + urllib.parse.urlencode(params))
    return list(data.get('query', {}).get('pages', {}).values())

def normalize(page, safe_url, licenses_of):
    if not isinstance(page, dict):
        page = {}
    info = page.get('imageinfo') or [{}]
    if not isinstance(info, list) or not info or not isinstance(info[0], dict):
        info = {}
    else:
        info = info[0]
    ext = info.get('extmetadata') or {}
    if not isinstance(ext, dict):
        ext = {}
    def val(k):
        item = ext.get(k)
        if isinstance(item, dict):
            return clean(item.get('value', ''))
        return clean(item) if isinstance(item, str) else ''
    url = info.get('url', '')
    license_url = val('LicenseUrl')
    if license_url.startswith('//'):
        license_url = 'https:' + license_url
    lics = licenses_of({'licenseurl': license_url})
    valid = bool(lics) and safe_url(url, {'upload.wikimedia.org'}) and info.get('mime', '').startswith('audio/')
    title = page.get('title', '')
    path = urllib.parse.urlsplit(url).path
    suffix = path.rsplit('.', 1)[-1].lower() if '.' in path else ''
    fmt = suffix.upper() if suffix else '音频'
    lossless = suffix in ('flac', 'wav', 'aif', 'aiff')
    quality = ('无损 ' + fmt) if lossless else ('高音质 ' + fmt if valid else '许可待核实')
    return {'id': 'commons:' + title, 'title': val('ObjectName') or title.removeprefix('File:'),
            'artist': val('Artist') or '查看文件页署名', 'album': '', 'cover': '',
            'url': info.get('descriptionurl', 'https://commons.wikimedia.org/wiki/' + urllib.parse.quote(title)),
            'preview': url if valid else '', 'source': 'Wikimedia Commons',
            'downloadable': valid, 'license': (val('LicenseShortName') + ' · ' + license_url) if valid else '许可待核实',
            'format': fmt, 'lossless': bool(valid and lossless), 'quality': quality if valid else '许可待核实',
            '_downloadUrl': url, '_licenseUrl': license_url}

def search(fetch, safe_url, licenses_of, q, kind):
    term = re.sub(r'[^\w\s\u3400-\u9fff-]', ' ', q).strip()
    params = {'action': 'query', 'format': 'json', 'generator': 'search',
              'gsrsearch': 'filetype:audio ' + term, 'gsrnamespace': 6, 'gsrlimit': 20,
              'prop': 'imageinfo', 'iiprop': 'url|extmetadata|mime'}
    data = fetch(API + '?' + urllib.parse.urlencode(params))
    rows = [normalize(p, safe_url, licenses_of) for p in data.get('query', {}).get('pages', {}).values()]
    return [{k: v for k, v in r.items() if not k.startswith('_')} for r in rows]
