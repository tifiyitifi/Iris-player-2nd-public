import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/webdav_discovery/view/gated_webdav_connect.dart';
import 'package:iris/features/webdav_discovery/view/webdav_connect_loop.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/l10n/app_localizations_zh.dart';
import 'package:iris/models/enums/storage_list_error.dart';

/// The connect retry loop, against real gates and a real navigator.
///
/// The loop exists because the shape was written out per call site and the
/// copies drifted: each one re-entered its own lock-guarded entry function to
/// retry, so the retry inherited the lock the previous attempt was still
/// holding and returned without dialling anything — a "retry" button that does
/// nothing, which is the one failure a user cannot work around. These pin the
/// properties that make the retry real:
///
///  * choosing retry runs the attempt again, however many times it is chosen;
///  * the lock is released BEFORE the failure dialog is raised, so the run that
///    follows a retry is not competing with the run that produced the dialog;
///  * cancel and edit end the loop without a second attempt, and an abandoned
///    attempt is never explained at all.
void main() {
  /// Records the order the lock and the dialog are taken in, which is the
  /// whole point: a release recorded after the dialog opened is the bug.
  final timeline = <String>[];

  setUp(() => timeline.clear());

  /// A stand-in for a storage tile: one tappable row inside a navigator, which
  /// is what a gate needs a root [NavigatorState] from.
  Future<NavigatorState> openTile(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: [
        const _SyncZhLocalizationsDelegate(),
        ...AppLocalizations.localizationsDelegates.skip(1),
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: [_DialogTimeline(timeline)],
      home: Scaffold(
        body: Builder(
          builder: (context) =>
              TextButton(onPressed: () {}, child: const Text('tile')),
        ),
      ),
    ));
    // gen-l10n deferred chunks load asynchronously; pump fake time until the
    // localized subtree is up (a real Future.delayed would never complete
    // inside the test's fake clock).
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find.text('tile').evaluate().isNotEmpty) break;
    }
    expect(find.text('tile'), findsOneWidget);
    return Navigator.of(tester.element(find.text('tile')), rootNavigator: true);
  }

  testWidgets('a retry runs the attempt again, and again, and again',
      (tester) async {
    final navigator = await openTile(tester);
    var attempts = 0;

    final pending = runRemoteConnectLoop<String>(
      attempt: (index) async {
        attempts++;
        final gate = GatedWebDavConnect(endpoint: '192.168.1.*')
          ..arm(navigator: navigator);
        if (index < 3) {
          return ConnectAttempt<String>.failed(
            errorKind: StorageListErrorKind.unreachable,
            errorDetail: 'no candidate host answered',
            endpoint: '192.168.1.5',
            gate: gate,
          );
        }
        await gate.succeed();
        gate.dispose();
        return const ConnectAttempt<String>.connected('resolved');
      },
      onEdit: () async => fail('edit must not be reachable here'),
      onRunningChanged: (running) =>
          timeline.add(running ? 'acquire' : 'release'),
    );

    for (var i = 0; i < 3; i++) {
      await tester.pump();
      expect(attempts, i + 1, reason: 'the attempt before the first dialog');
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
    }
    await tester.pump();

    final result = await pending;
    expect(attempts, 4, reason: 'every retry has to reach a real attempt');
    expect(result.connected, isTrue);
    expect(result.value, 'resolved');
  });

  testWidgets('the lock is released before the failure dialog is raised',
      (tester) async {
    final navigator = await openTile(tester);

    final pending = runRemoteConnectLoop<String>(
      attempt: (_) async {
        final gate = GatedWebDavConnect(endpoint: '192.168.1.*')
          ..arm(navigator: navigator);
        return ConnectAttempt<String>.failed(
          errorKind: StorageListErrorKind.unreachable,
          gate: gate,
        );
      },
      onEdit: () async {},
      onRunningChanged: (running) =>
          timeline.add(running ? 'acquire' : 'release'),
    );

    await tester.pump();
    expect(find.text('重试'), findsOneWidget);

    expect(
      timeline,
      containsAllInOrder(<String>['acquire', 'release', 'dialog']),
      reason: 'a dialog raised while the lock is still held is a retry the '
          'next attempt cannot take',
    );
    expect(
      timeline.indexOf('release'),
      lessThan(timeline.indexOf('dialog')),
      reason: 'the run is over the moment the failure is known; the dialog it '
          'turns into is the user thinking, not work in flight',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await pending).connected, isFalse);
  });

  testWidgets('cancel ends the loop without a second attempt', (tester) async {
    final navigator = await openTile(tester);
    var attempts = 0;
    var edits = 0;

    final pending = runRemoteConnectLoop<String>(
      attempt: (_) async {
        attempts++;
        return ConnectAttempt<String>.failed(
          errorKind: StorageListErrorKind.unauthorized,
          gate: GatedWebDavConnect(endpoint: '192.168.1.*')
            ..arm(navigator: navigator),
        );
      },
      onEdit: () async => edits++,
      onRunningChanged: (running) =>
          timeline.add(running ? 'acquire' : 'release'),
    );

    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    final result = await pending;
    expect(attempts, 1);
    expect(edits, 0);
    expect(result.state, ConnectLoopState.settled);
  });

  testWidgets('edit opens the form once and settles', (tester) async {
    final navigator = await openTile(tester);
    var attempts = 0;
    var edits = 0;

    final pending = runRemoteConnectLoop<String>(
      attempt: (_) async {
        attempts++;
        return ConnectAttempt<String>.failed(
          errorKind: StorageListErrorKind.unreachable,
          gate: GatedWebDavConnect(endpoint: '192.168.1.*')
            ..arm(navigator: navigator),
        );
      },
      onEdit: () async => edits++,
      onRunningChanged: (running) =>
          timeline.add(running ? 'acquire' : 'release'),
    );

    await tester.pump();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    final result = await pending;
    expect(attempts, 1);
    expect(edits, 1);
    expect(result.state, ConnectLoopState.settled);
  });

  testWidgets('an abandoned attempt is never explained', (tester) async {
    final navigator = await openTile(tester);
    var attempts = 0;

    final pending = runRemoteConnectLoop<String>(
      attempt: (_) async {
        attempts++;
        final gate = GatedWebDavConnect(endpoint: '192.168.1.*')
          ..arm(navigator: navigator);
        // The user dismissed the progress window: the gate is the attempt's to
        // take down, and nothing is known about the far end.
        await gate.cancel();
        gate.dispose();
        return const ConnectAttempt<String>.abandoned();
      },
      onEdit: () async => fail('an abandoned run must not offer the form'),
      onRunningChanged: (running) =>
          timeline.add(running ? 'acquire' : 'release'),
    );
    await tester.pumpAndSettle();

    final result = await pending;
    expect(attempts, 1);
    expect(result.state, ConnectLoopState.abandoned);
    expect(timeline, isNot(contains('dialog')),
        reason: 'nothing is known about the far end, so nothing is reported');
  });
}

class _DialogTimeline extends NavigatorObserver {
  _DialogTimeline(this.timeline);

  final List<String> timeline;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) timeline.add('dialog');
    super.didPush(route, previousRoute);
  }
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
