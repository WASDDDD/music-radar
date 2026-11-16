"""离线关键行为测试：不触网、不修改正式榜单数据库。"""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import server

class RightsTests(unittest.TestCase):
    def test_license_recognition(self):
        self.assertTrue(server.licenses_of({'licenseurl': 'https://creativecommons.org/licenses/by/4.0/'}))
        self.assertFalse(server.licenses_of({'licenseurl': 'https://creativecommons.org.evil.test/licenses/by/4.0/'}))
        self.assertFalse(server.licenses_of({}))

    def test_restricted_or_private_audio_is_blocked(self):
        meta = {'licenseurl': 'https://creativecommons.org/licenses/by/4.0/'}
        self.assertIsNone(server.choose_archive_file({'metadata': meta, 'files': [{'name': 'x.mp3', 'private': 'true'}]}))
        self.assertIsNone(server.choose_archive_file({'metadata': dict(meta, **{'access-restricted-item': 'true'}), 'files': [{'name': 'x.mp3'}]}))
        self.assertIsNone(server.choose_archive_file({'metadata': {}, 'files': [{'name': 'x.mp3'}]}))

    def test_download_rechecks_source_and_logs(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(server, 'DB', Path(temp) / 'test.db'):
            server.init_db()
            data = {'metadata': {'title': 'Test', 'licenseurl': 'https://creativecommons.org/licenses/by-sa/4.0/'}, 'files': [{'name': 'song.mp3'}]}
            with patch.object(server, 'archive_detail', return_value=data) as remote:
                result = server.authorize_download('archive:test')
                self.assertEqual(result['url'], 'https://archive.org/download/test/song.mp3')
                remote.assert_called_once_with('test')
            with self.assertRaises(PermissionError):
                server.authorize_download('itunes:123')
            with server.connect() as db:
                flags = [r[0] for r in db.execute('SELECT allowed FROM audit ORDER BY id')]
            self.assertEqual(flags, [1, 0])

    def test_network_path_guards(self):
        self.assertFalse(server.safe_url('https://archive.org.evil.test/file', {'archive.org'}))
        self.assertFalse(server.safe_url('http://archive.org/file'))
        with self.assertRaises(ValueError):
            server.archive_detail('../private')

class ChartTests(unittest.TestCase):
    def test_daily_snapshot_is_idempotent_and_history_honest(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(server, 'DB', Path(temp) / 'test.db'):
            server.init_db()
            feed = {'playlist': {'tracks': [{'id': 1, 'name': 'song',
                                              'ar': [{'name': 'artist'}], 'al': {'name': 'album', 'picUrl': ''}}]}}
            with patch.object(server, '_netease_fetch', return_value=feed):
                self.assertTrue(server.sync_chart())
                self.assertTrue(server.sync_chart())
            data = server.charts('weekly')
            self.assertEqual(data['coverageDays'], 1)
            self.assertEqual(data['expectedDays'], 7)
            self.assertEqual(data['items'][0]['score'], 100)
            self.assertIn('历史不足', data['message'])
            with patch.object(server, '_netease_fetch', side_effect=TimeoutError):
                self.assertFalse(server.sync_chart())
            self.assertEqual(len(server.charts('daily')['items']), 1)
            self.assertTrue(server.charts('daily')['error'])

class SourceTests(unittest.TestCase):
    def test_audius_filters_unstreamable_and_gating(self):
        fake = {'data': [
            {'id': 'a1', 'title': 'Playable', 'is_streamable': True, 'is_stream_gated': False,
             'is_downloadable': True, 'is_download_gated': False, 'user': {'name': 'U'}, 'permalink': '/u/track'},
            {'id': 'a2', 'title': 'Locked', 'is_streamable': False, 'is_stream_gated': False, 'user': {}},
            {'id': 'a3', 'title': 'Gated', 'is_streamable': True, 'is_stream_gated': True, 'user': {}},
        ]}
        with patch.object(server, 'fetch_json', return_value=fake):
            rows = server.search_audius('x', 'track')
        self.assertEqual([r['title'] for r in rows], ['Playable'])
        self.assertEqual(rows[0]['id'], 'audius:a1')
        self.assertTrue(rows[0]['downloadable'])
        self.assertIn('/stream?', rows[0]['preview'])

    def test_musicbrainz_maps_metadata(self):
        fake = {'recordings': [{'id': 'mb1', 'title': 'Song',
                                'artist-credit': [{'name': 'Artist', 'artist': {'id': 'x'}}],
                                'releases': [{'title': 'Album'}]}]}
        with patch.object(server, 'fetch_json', return_value=fake):
            rows = server.search_musicbrainz('song', 'track')
        self.assertEqual(rows[0]['id'], 'musicbrainz:mb1')
        self.assertEqual(rows[0]['artist'], 'Artist')
        self.assertEqual(rows[0]['album'], 'Album')
        self.assertFalse(rows[0]['downloadable'])
        self.assertEqual(rows[0]['url'], 'https://musicbrainz.org/recording/mb1')

    def test_audius_download_requires_platform_permission(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(server, 'DB', Path(temp) / 'test.db'):
            server.init_db()
            denied = {'data': {'is_downloadable': False, 'is_download_gated': False}}
            with patch.object(server, 'fetch_json', return_value=denied):
                with self.assertRaises(PermissionError):
                    server.authorize_download('audius:abc123')
            allowed = {'data': {'title': 'T', 'is_downloadable': True, 'is_download_gated': False, 'license': 'CC'}}
            with patch.object(server, 'fetch_json', return_value=allowed):
                res = server.authorize_download('audius:abc123')
            self.assertIn('/download?', res['url'])

    def test_quality_fields_and_archive_prefers_lossless(self):
        self.assertTrue(server.quality_fields('flac')['lossless'])
        self.assertTrue(server.quality_fields('WAV')['lossless'])
        self.assertFalse(server.quality_fields('mp3')['lossless'])
        data = {'metadata': {'licenseurl': 'https://creativecommons.org/licenses/by/4.0/'},
                'files': [{'name': 'a.mp3'}, {'name': 'b.flac'}, {'name': 'c.wav'}]}
        self.assertEqual(server.choose_archive_file(data)['name'], 'b.flac')

    def test_ccmixter_pick_prefers_lossless_and_skips_zip(self):
        files = [
            {'file_nicname': 'mp3', 'download_url': 'https://ccmixter.org/content/a.mp3'},
            {'file_nicname': 'zip', 'download_url': 'https://ccmixter.org/content/a.zip'},
            {'file_nicname': 'flac', 'download_url': 'https://ccmixter.org/content/a.flac'},
        ]
        pick = server._ccmixter_pick(files)
        self.assertIsNotNone(pick)
        self.assertEqual(pick[1], 'flac')
        # Non-ccmixter hosts must be rejected (no SSRF into the stream proxy).
        self.assertIsNone(server._ccmixter_pick([{'download_url': 'https://evil.example/x.flac'}]))

if __name__ == '__main__':
    unittest.main()