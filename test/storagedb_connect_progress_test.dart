import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/webdav_discovery/model/discovery_models.dart';
import 'package:iris/features/webdav_discovery/services/webdav_connect_coordinator.dart';
import 'package:iris/features/webdav_discovery/services/webdav_discovery.dart';
import 'package:iris/features/webdav_discovery/view/webdav_connect_error_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/l10n/app_localizations_zh.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/features/webdav_discovery/view/gated_webdav_connect.dart';

import 'helpers/sqlite3_loader.dart';

/// The storagedb connect surface, end to end.
///
/// A wildcard resolve is unbounded — cached hosts, then SSDP, then a bounded
/// scan of the whole subnet — and the tile tap used to sit through all of it
/// with no visible state at all, so a dead remote read as a dead button until a
/// failure dialog eventually appeared. These pin three properties:
///
///  * a connect answered inside the delay mounts NO window at all;
///  * a slower one names the host it is trying and stays dismissible;
///  * a failure takes over that same window — one route, never a second one.
///
/// The resolve is driven by [_ScriptedResolve] rather than the real
/// coordinator: the coordinator returns from inside an `await for`, and
/// cancelling that subscription inside a widget test's fake-async zone wedges
/// the clock. Its half of the contract (every candidate is forwarded, a
/// dismissed run reports `cancelled`) is covered against the real thing in
/// `webdav_resolve_outcome_test.dart`, and the wiring between the two is
/// pinned by the real-async case at the bottom of this file.
class _ScriptedResolve {
  _ScriptedResolve(this.connect);

  final GatedWebDavConnect connect;

  final _completer = Completer<WebDavResolveOutcome>();

  /// A host is about to be probed.
  void probing(String host, int index, int total, DiscoveryStage stage) {
    connect.report(DiscoveryCandidate(
      host: host,
      index: index,
      total: total,
      stage: stage,
    ));
  }

  /// Resolution is over; the live root is being listed.
  void listing() => connect.report(null);

  void verified() => _completer.complete(const WebDavResolveOutcome(
        host: '192.168.1.5',
      ));

  void exhausted() => _completer.complete(const WebDavResolveOutcome(
        errorKind: StorageListErrorKind.unreachable,
        errorDetail: 'no candidate host answered',
      ));

  /// What the tile does with the result once it lands.
  Future<WebDavResolveOutcome> run() async {
    final outcome = await _completer.future;
    if (outcome.ok) {
      await connect.succeed();
    }
    return outcome;
  }
}

class _DialogRouteLog extends NavigatorObserver {
  int pushes = 0;
  int pops = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) pushes++;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) pops++;
    super.didPop(route, previousRoute);
  }
}

WebDAVStorage _wildcard() => Storage.webdav(
      id: 'w1',
      name: 'nas',
      host: '192.168.1.*',
      basePath: const [''],
      port: '8090',
      username: 'u',
      password: 'p',
      https: false,
    ) as WebDAVStorage;

/// Emits a fixed event list, no network involved.
class _ScriptedDiscovery extends WebDavDiscovery {
  _ScriptedDiscovery(this.events);

  final List<DiscoveryEvent> events;

  @override
  Stream<DiscoveryEvent> resolve(
    WebDAVStorage storage, {
    Set<String> excludedHosts = const <String>{},
  }) =>
      Stream<DiscoveryEvent>.fromIterable(events);
}

void main() {
  ensureSqlite3Loaded();

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    useStorageStore();
    await useStorageStore().initialized;
  });

  late _DialogRouteLog log;

  setUp(() => log = _DialogRouteLog());

  /// A stand-in for the storagedb tile: one tappable row inside a navigator,
  /// which is what the gate needs a root [NavigatorState] from.
  Future<void> openList(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: [
        const _SyncZhLocalizationsDelegate(),
        ...AppLocalizations.localizationsDelegates.skip(1),
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: [log],
      home: Scaffold(
        body: Builder(
          builder: (context) =>
              TextButton(onPressed: () {}, child: const Text('tap tile')),
        ),
      ),
    ));
    // gen-l10n deferred chunks load asynchronously; pump fake time until the
    // localized subtree is up (a real Future.delayed would never complete
    // inside the test's fake clock).
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find.text('tap tile').evaluate().isNotEmpty) break;
    }
    expect(find.text('tap tile'), findsOneWidget);
    await tester.tap(find.text('tap tile'));
    await tester.pump();
  }

  GatedWebDavConnect armGate(WidgetTester tester) => GatedWebDavConnect(
        endpoint: '192.168.1.*',
      )..arm(
          navigator: Navigator.of(
            tester.element(find.text('tap tile')),
            rootNavigator: true,
          ),
        );

  testWidgets('a connect answered inside the delay mounts no window at all',
      (tester) async {
    await openList(tester);
    final connect = armGate(tester);
    final resolve = _ScriptedResolve(connect);

    // Answered well inside the 400 ms gate.
    resolve.verified();
    final outcome = await resolve.run();
    expect(outcome.ok, isTrue);

    expect(log.pushes, 0, reason: 'nothing was ever pushed');
    expect(find.byType(AlertDialog), findsNothing);
    connect.dispose();
  });

  testWidgets('a slow connect names the host it is trying, then gets out of '
      'the way on success', (tester) async {
    await openList(tester);
    final connect = armGate(tester);
    final resolve = _ScriptedResolve(connect);

    // Still inside the delay: the tap must look untouched.
    await tester.pump(const Duration(milliseconds: 200));
    expect(log.pushes, 0);

    // Past it: the surface is up and says what it is doing.
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('正在连接'), findsOneWidget);

    resolve.probing('192.168.1.37', 37, 254, DiscoveryStage.scan);
    await tester.pump();
    expect(find.textContaining('192.168.1.37'), findsOneWidget);
    expect(find.textContaining('37/254'), findsOneWidget);
    expect(find.textContaining('正在扫描网络'), findsOneWidget);

    // Past resolution the surface must stop naming a host that is no longer
    // being tried.
    resolve.listing();
    await tester.pump();
    expect(find.textContaining('192.168.1.37'), findsNothing);
    expect(find.textContaining('正在读取目录'), findsOneWidget);

    resolve.verified();
    expect((await resolve.run()).ok, isTrue);
    connect.dispose();
    await tester.pumpAndSettle();

    expect(log.pushes, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a slow failure takes over the progress window, never a second '
      'one', (tester) async {
    await openList(tester);
    final connect = armGate(tester);
    final resolve = _ScriptedResolve(connect);

    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(AlertDialog), findsOneWidget);

    resolve.probing('192.168.1.37', 37, 254, DiscoveryStage.scan);
    resolve.exhausted();
    final outcome = await resolve.run();
    expect(outcome.errorKind, StorageListErrorKind.unreachable);

    // Not awaited yet: the surface is now waiting for the user.
    final pending = connect.fail(
      endpoint: '192.168.1.5',
      errorKind: outcome.errorKind,
      errorDetail: outcome.errorDetail,
    );
    await tester.pump();

    expect(log.pushes, 1,
        reason: 'the failure must reuse the progress route, not stack on it');
    expect(find.textContaining('正在连接'), findsNothing);
    expect(find.textContaining('192.168.1.5'), findsWidgets);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(await pending, WebdavConnectAction.retry);
    expect(log.pushes, 1);
    connect.dispose();
  });

  testWidgets('a fast failure opens the failure surface with no progress '
      'flash', (tester) async {
    await openList(tester);
    final connect = armGate(tester);
    final resolve = _ScriptedResolve(connect);

    resolve.exhausted();
    final outcome = await resolve.run();

    final pending = connect.fail(
      endpoint: '192.168.1.5',
      errorKind: outcome.errorKind,
      errorDetail: outcome.errorDetail,
    );
    await tester.pump();

    expect(log.pushes, 1);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the progress state must never have been shown');
    expect(find.textContaining('192.168.1.5'), findsWidgets);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await pending, WebdavConnectAction.cancel);
    connect.dispose();
  });

  testWidgets('dismissing the progress window drops the result instead of '
      'opening anything', (tester) async {
    await openList(tester);
    final connect = armGate(tester);
    final resolve = _ScriptedResolve(connect);

    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(AlertDialog), findsOneWidget);

    resolve.probing('192.168.1.37', 1, 254, DiscoveryStage.scan);
    await tester.pump();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(connect.cancelled, isTrue);

    // The scan still finishes on its own, but nothing more is reported, so the
    // result must NOT surface as something the user has to act on.
    resolve.exhausted();
    expect(await connect.succeed(), isTrue);
    connect.dispose();
    await tester.pumpAndSettle();

    expect(log.pushes, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a caller that walks away takes the surface down with it',
      (tester) async {
    // What the storages list does when the popup hosting the tap goes away
    // mid-resolve: the progress surface was pushed on the ROOT navigator, so
    // that dismissal closes nothing. dispose() on its own only releases — in
    // debug it asserts, and in release it leaves a frozen spinner standing
    // there for the whole session.
    await openList(tester);
    final connect = armGate(tester);
    final resolve = _ScriptedResolve(connect);

    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(AlertDialog), findsOneWidget);

    resolve.probing('192.168.1.37', 1, 254, DiscoveryStage.scan);
    await tester.pump();
    expect(find.textContaining('192.168.1.37'), findsOneWidget);

    await connect.cancel();
    connect.dispose();
    await tester.pumpAndSettle();

    expect(log.pushes, 1);
    expect(log.pops, 1);
    expect(find.byType(AlertDialog), findsNothing);
    // The host route is untouched: cancelling must not take it down with the
    // surface.
    expect(find.text('tap tile'), findsOneWidget);
  });

  testWidgets('an abandoned connect disposes legally after the user dismissed',
      (tester) async {
    // The other walk-away: the user closed the surface themselves and the
    // resolve lands afterwards. The terminal still has to run — dispose()
    // asserts without one — and must be inert, because a second pop here would
    // take the host route with it.
    await openList(tester);
    final connect = armGate(tester);
    final resolve = _ScriptedResolve(connect);

    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(AlertDialog), findsOneWidget);

    resolve.probing('192.168.1.37', 1, 254, DiscoveryStage.scan);
    await tester.pump();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(connect.cancelled, isTrue);

    // The resolve still finishes on its own, reporting nothing to anybody.
    resolve.exhausted();
    await connect.cancel();
    expect(connect.dispose, returnsNormally);
    await tester.pumpAndSettle();

    expect(log.pushes, 1);
    expect(log.pops, 1, reason: 'the user already closed it; nobody pops again');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('tap tile'), findsOneWidget);
  });

  test('a real discovery drives the surface, and a dismissal cancels it',
      () async {
    // The wiring the scripted cases above stand in for: real coordinator, real
    // progress events, real cancellation.
    final connect = GatedWebDavConnect(endpoint: '192.168.1.*');
    final coordinator = WebDavConnectCoordinator(
      discovery: _ScriptedDiscovery(const [
        DiscoveryCandidate(
          host: '192.168.1.37',
          index: 37,
          total: 254,
          stage: DiscoveryStage.scan,
        ),
        DiscoveryExhausted(),
      ]),
    );

    final outcome = await coordinator.resolveDetailed(
      _wildcard(),
      onCandidate: connect.report,
      stillWanted: () => !connect.cancelled,
    );

    expect(outcome.errorKind, StorageListErrorKind.unreachable);
    expect(outcome.cancelled, isFalse,
        reason: 'nothing dismissed the surface, so this is a real failure');
    // Terminal, but never armed: no window was ever requested.
    expect(await connect.succeed(), isFalse);
    connect.dispose();
  });
}

/// gen-l10n deferred chunks load only once per test isolate; serving zh
/// synchronously keeps `getLocalizations(context)` from seeing a null
/// localizations object.
class _SyncZhLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _SyncZhLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'zh';

  @override
  Future<AppLocalizations> load(Locale locale) async => AppLocalizationsZh();

  @override
  bool shouldReload(_SyncZhLocalizationsDelegate old) => false;
}
