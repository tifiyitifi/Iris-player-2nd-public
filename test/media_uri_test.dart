import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/webdav.dart' show webdavUriForEndpoint;
import 'package:iris/utils/path_conv.dart';

WebDAVStorage _webdav({
  String host = '192.168.*.*',
  List<String> resolvedHosts = const <String>[],
  String port = '8090',
  bool https = false,
  List<String> basePath = const <String>['/'],
}) =>
    WebDAVStorage(
      id: 's1',
      name: 'nas',
      host: host,
      resolvedHosts: resolvedHosts,
      basePath: basePath,
      port: port,
      username: 'u',
      password: 'p',
      https: https,
    );

FTPStorage _ftp({String host = '192.168.1.9', String port = '21'}) => FTPStorage(
      id: 'f1',
      name: 'ftp',
      host: host,
      basePath: const <String>['/'],
      port: port,
      username: 'u',
      password: 'p',
    );

/// The DB keeps the storage-relative path as the identity and the remote address
/// is DERIVED from the storage record, so a wildcard entry tracks its current
/// resolution instead of baking a host into `media_nodes`.
void main() {
  group('webdavPlayableUri', () {
    test('uses the resolved host for a wildcard entry', () {
      expect(
        webdavPlayableUri(
            _webdav(resolvedHosts: const <String>['192.168.1.4']),
            const <String>['a.mp4']),
        'http://192.168.1.4:8090/a.mp4',
      );
    });

    test('falls back to the configured host when nothing is resolved', () {
      expect(
        webdavPlayableUri(_webdav(host: 'nas.local'), const <String>['a.mp4']),
        'http://nas.local:8090/a.mp4',
      );
    });

    test('honours https and a non-default port', () {
      expect(
        webdavPlayableUri(
            _webdav(
                https: true,
                port: '8443',
                resolvedHosts: const <String>['192.168.1.4']),
            const <String>['a.mp4']),
        'https://192.168.1.4:8443/a.mp4',
      );
    });

    test('keeps nested segments and a non-root base path', () {
      expect(
        webdavPlayableUri(
            _webdav(
                basePath: const <String>['/dav'],
                resolvedHosts: const <String>['192.168.1.4']),
            const <String>['dav', 'anime', 'b.mp4']),
        'http://192.168.1.4:8090/dav/anime/b.mp4',
      );
    });

    test('tolerates a legacy slash-prefixed node path', () {
      expect(
        webdavPlayableUri(
            _webdav(resolvedHosts: const <String>['192.168.1.4']),
            const <String>['/', 'a.mp4']),
        'http://192.168.1.4:8090/a.mp4',
      );
    });
  });

  group('ftpPlayableUri', () {
    test('builds the relative form the player proxy-prefixes', () {
      expect(
        ftpPlayableUri(_ftp(), const <String>['anime', 'b.mp4']),
        'ftp?host=192.168.1.9&port=21&path=/anime/b.mp4',
      );
    });

    test('keeps the leading slash the listing producer uses', () {
      expect(
        ftpPlayableUri(_ftp(), const <String>['a.mp4']),
        'ftp?host=192.168.1.9&port=21&path=/a.mp4',
      );
    });

    test('percent-encodes reserved characters in the path', () {
      // `Uri.encodeFull` left `&` / `#` raw, so the proxy read only `/a`.
      final amp = ftpPlayableUri(_ftp(), const <String>['a&b.srt']);
      expect(amp, 'ftp?host=192.168.1.9&port=21&path=/a%26b.srt');
      expect(Uri.parse(amp).queryParameters['path'], '/a&b.srt');

      final hash = ftpPlayableUri(_ftp(), const <String>['a#b.srt']);
      expect(Uri.parse(hash).queryParameters['path'], '/a#b.srt');

      // Space / sub-delimiters still round-trip through the proxy accessor.
      expect(
        Uri.parse(ftpPlayableUri(_ftp(), const <String>['a b,c(d).srt']))
            .queryParameters['path'],
        '/a b,c(d).srt',
      );
    });

    test('mediaNodePlayableUri derives it for FTP rows', () {
      expect(
        mediaNodePlayableUri(_ftp(), const <String>['anime', 'b.mp4']),
        'ftp?host=192.168.1.9&port=21&path=/anime/b.mp4',
      );
    });
  });

  group('mediaNodePlayableUri', () {
    test('prefers a persisted SAF uri', () {
      expect(
        mediaNodePlayableUri(
          _webdav(resolvedHosts: const <String>['192.168.1.4']),
          const <String>['a.mp4'],
          uri: 'content://tree/a.mp4',
        ),
        'content://tree/a.mp4',
      );
    });

    test('derives the WebDAV address from the storage record', () {
      expect(
        mediaNodePlayableUri(
          _webdav(resolvedHosts: const <String>['192.168.1.4']),
          const <String>['anime', 'b.mp4'],
        ),
        'http://192.168.1.4:8090/anime/b.mp4',
      );
    });

    test('local storages and unknown storages keep the path form', () {
      final local = Storage.local(
        id: 'l1',
        type: StorageType.sdcard,
        name: 'sd',
        basePath: const <String>['/sdcard'],
      );
      expect(
        mediaNodePlayableUri(local, const <String>['sdcard', 'x.mp4']),
        playableUri(const <String>['sdcard', 'x.mp4']),
      );
      expect(
        mediaNodePlayableUri(null, const <String>['a', 'x.mp4']),
        playableUri(const <String>['a', 'x.mp4']),
      );
    });
  });

  // A subtitle's address is derived at hand-off time, from the storage record,
  // so it can never disagree with the video's address (which is derived by
  // webdavPlayableUri at open time).
  Subtitle subtitleOf(String uri) => Subtitle(name: 'zh-ru', uri: uri);

  group('webdavUriForEndpoint', () {
    test('is the ONE encoder shared by the listing and by playback', () {
      final storage = _webdav(resolvedHosts: const <String>['192.168.1.6']);
      const name = '[4K] (SunDub, VOX-S)©.zh-ru.ass';
      expect(
        webdavUriForEndpoint(
          https: false,
          host: '192.168.1.6',
          port: '8090',
          segments: const <String>['rusia', name],
        ),
        webdavPlayableUri(storage, const <String>['rusia', name]),
      );
    });

    test('keeps sub-delimiters unescaped (the browser/listing shape)', () {
      expect(
        webdavUriForEndpoint(
          https: false,
          host: 'h',
          port: '8090',
          segments: const <String>['a, b & c'],
        ),
        'http://h:8090/a,%20b%20&%20c',
      );
    });
  });

  group('subtitlePlayableUri', () {
    test('WebDAV rebuilds the authority from the CURRENT storage record', () {
      // The entry was listed while it resolved to .4; it now answers on .6.
      final storage = _webdav(resolvedHosts: const <String>['192.168.1.6']);
      expect(
        subtitlePlayableUri(
          storage,
          subtitleOf('http://192.168.1.4:8090/dav/anime/b.zh-ru.ass'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://192.168.1.6:8090/dav/anime/b.zh-ru.ass',
      );
    });

    test('WebDAV re-encodes with the canonical builder (parity with video)', () {
      final storage = _webdav(resolvedHosts: const <String>['192.168.1.6']);
      // Listing form (`%2C` from the legacy encoder) must come out identical to
      // the video address built from the same name.
      expect(
        subtitlePlayableUri(
          storage,
          subtitleOf(
              'http://192.168.1.6:8090/rusia/%5B4K%5D%20(SunDub%2C%20VOX-S)%C2%A9.zh-ru.ass'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        webdavPlayableUri(
          storage,
          const <String>['rusia', '[4K] (SunDub, VOX-S)©.zh-ru.ass'],
        ),
      );
    });

    test('FTP prefixes the local proxy, credentials never in the URL', () {
      expect(
        subtitlePlayableUri(
          _ftp(),
          subtitleOf('ftp?host=192.168.1.9&port=21&path=/a/b.ass'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://localhost:8760/ftp?host=192.168.1.9&port=21&path=/a/b.ass',
      );
    });

    test('FTP rebuilds the host from the CURRENT storage record', () {
      // The address baked 192.168.1.9 at list time; the entry now answers on .77.
      // The video follows the storage, so the subtitle must too.
      expect(
        subtitlePlayableUri(
          _ftp(host: '192.168.1.77'),
          subtitleOf('ftp?host=192.168.1.9&port=21&path=/a/b.ass'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://localhost:8760/ftp?host=192.168.1.77&port=21&path=/a/b.ass',
      );
    });

    test('FTP keeps the old host only when the address cannot be parsed', () {
      expect(
        subtitlePlayableUri(
          _ftp(host: '192.168.1.77'),
          subtitleOf('/a/b.ass'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://localhost:8760//a/b.ass',
      );
    });

    test('FTP rebuilds a legacy path= carrying an unencoded & verbatim', () {
      // A pre-encoding row stored the file name `/a&b.srt` unencoded, so
      // `queryParameters['path']` truncates it to `/a` and the rebuild would
      // point at the WRONG file. The raw `path=` tail (always last) keeps it.
      expect(
        subtitlePlayableUri(
          _ftp(),
          subtitleOf('ftp?host=192.168.1.9&port=21&path=/a&b.srt'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://localhost:8760/ftp?host=192.168.1.9&port=21&path=/a%26b.srt',
      );
    });

    test('WebDAV preserves a signed query while refreshing the authority', () {
      final storage = _webdav(resolvedHosts: const <String>['192.168.1.6']);
      expect(
        subtitlePlayableUri(
          storage,
          subtitleOf('http://192.168.1.4:8090/dav/b.ass?token=abc&exp=99'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://192.168.1.6:8090/dav/b.ass?token=abc&exp=99',
      );
    });

    test('WebDAV preserves a fragment', () {
      final storage = _webdav(resolvedHosts: const <String>['192.168.1.6']);
      expect(
        subtitlePlayableUri(
          storage,
          subtitleOf('http://192.168.1.4:8090/dav/b.ass#track1'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://192.168.1.6:8090/dav/b.ass#track1',
      );
    });

    test('WebDAV re-encodes a # inside the file name', () {
      final storage = _webdav(resolvedHosts: const <String>['192.168.1.6']);
      expect(
        subtitlePlayableUri(
          storage,
          subtitleOf('http://192.168.1.4:8090/dav/a%23b.ass'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://192.168.1.6:8090/dav/a%23b.ass',
      );
    });

    test('WebDAV falls back to the stored address on a malformed escape', () {
      final storage = _webdav(resolvedHosts: const <String>['192.168.1.6']);
      // `%FF` is not valid UTF-8, so the LAZY `pathSegments` accessor throws on
      // it. The track panel builds from this value, so it must get the stored
      // address instead of an exception.
      expect(
        subtitlePlayableUri(
          storage,
          subtitleOf('http://192.168.1.4:8090/dav/%FF.ass'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://192.168.1.4:8090/dav/%FF.ass',
      );
    });

    test('FTP falls back to the stored address on a malformed escape', () {
      // `queryParameters` (the `path=` read) throws on the same escape.
      expect(
        subtitlePlayableUri(
          _ftp(),
          subtitleOf('ftp?host=192.168.1.9&port=21&path=/a/%FF.ass'),
          mediaStreamUrl: 'http://localhost:8760',
        ),
        'http://localhost:8760/ftp?host=192.168.1.9&port=21&path=/a/%FF.ass',
      );
    });

    test('local / unknown storages keep the stored uri verbatim', () {
      final local = Storage.local(
        id: 'l1',
        type: StorageType.sdcard,
        name: 'sd',
        basePath: const <String>['/sdcard'],
      );
      expect(
        subtitlePlayableUri(local, subtitleOf('/sdcard/a.ass'),
            mediaStreamUrl: 'http://localhost:8760'),
        '/sdcard/a.ass',
      );
      expect(
        subtitlePlayableUri(null, subtitleOf('/x/a.ass'),
            mediaStreamUrl: 'http://localhost:8760'),
        '/x/a.ass',
      );
    });
  });
}
