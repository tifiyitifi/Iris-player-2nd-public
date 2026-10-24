import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/phone/one_handed_scrubber/view/phone_time_lens_scrubber.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/player.dart';
import 'package:provider/provider.dart';

/// The time-lens ±step buttons must use the player's OWN step path
/// (`MediaPlayer.forward` / `backward` → each hook's `seekRelative`).
///
/// Deciding the tail locally and calling `finishSeek` bypassed the shared
/// `decideStepTail` policy, the mpv-parity tail arm (`MpvSeekTailState`), the
/// EOF collapse and the media-switch gate (`gateStepPress`). A second tap
/// inside the queue-advance window then resolved against the PREVIOUS file's
/// duration and finished the entry that had just opened — one episode skipped.
///
/// These tests pin the delegation: the widget never seeks or finishes on its
/// own, whatever the position is.
class _Recorder {
  final List<int> forwards = <int>[];
  final List<int> backwards = <int>[];
  final List<Duration> seeks = <Duration>[];
  final List<Duration> finishes = <Duration>[];
}

MediaPlayer _player({
  required Duration position,
  required Duration duration,
  required bool playing,
  required _Recorder rec,
}) {
  return MediaPlayer(
    isInitializing: false,
    isPlaying: playing,
    externalSubtitles: const [],
    position: position,
    duration: duration,
    buffer: Duration.zero,
    width: 16,
    height: 9,
    saveProgress: () async {},
    play: () async {},
    pause: () async {},
    backward: (seconds) async => rec.backwards.add(seconds),
    forward: (seconds) async => rec.forwards.add(seconds),
    stepBackward: () async {},
    stepForward: () async {},
    seek: (Duration t) async => rec.seeks.add(t),
    finishSeek: (Duration t) async => rec.finishes.add(t),
  );
}

Widget _harness(MediaPlayer player) {
  return StoreScope(
    child: Provider<MediaPlayer>.value(
      value: player,
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: PhoneTimeLensScrubber(
              showControl: _noop,
              color: Colors.white,
              isLeftHanded: false,
            ),
          ),
        ),
      ),
    ),
  );
}

void _noop() {}

void main() {
  // AppState default: strict tail mode, 5s seek step.
  testWidgets('a forward press delegates to forward() — even at the tail',
      (tester) async {
    final rec = _Recorder();
    await tester.pumpWidget(_harness(_player(
      position: const Duration(seconds: 58),
      duration: const Duration(seconds: 60),
      playing: true,
      rec: rec,
    )));
    // Deferred l10n loads async; settle before tapping.
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.fast_forward_rounded));
    await tester.pumpAndSettle();

    // The hook owns the tail decision: it turns this press into the ordinary
    // relative step + the EOF collapse, so the widget must not finish locally.
    expect(rec.forwards, const [5]);
    expect(rec.seeks, isEmpty);
    expect(rec.finishes, isEmpty);
  });

  testWidgets('a backward press delegates to backward()', (tester) async {
    final rec = _Recorder();
    await tester.pumpWidget(_harness(_player(
      position: const Duration(seconds: 10),
      duration: const Duration(seconds: 60),
      playing: true,
      rec: rec,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.replay_rounded));
    await tester.pumpAndSettle();

    expect(rec.backwards, const [5]);
    expect(rec.seeks, isEmpty);
    expect(rec.finishes, isEmpty);
  });

  testWidgets('an unknown duration presses nothing', (tester) async {
    final rec = _Recorder();
    await tester.pumpWidget(_harness(_player(
      position: Duration.zero,
      duration: Duration.zero,
      playing: true,
      rec: rec,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.fast_forward_rounded));
    await tester.pumpAndSettle();

    expect(rec.forwards, isEmpty);
    expect(rec.seeks, isEmpty);
    expect(rec.finishes, isEmpty);
  });
}
