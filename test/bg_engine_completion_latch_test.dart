import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/models/store/app_state.dart' show PlayerBackend;

/// The completion hold exists to tell "the master ENDED" from "the master was
/// PAUSED" while the cross-file continuation resolves. It must end the moment
/// playback state is REALLY decided again — including an explicit pause — or
/// the transport mirror stays stood down for the rest of the session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BackgroundPlaybackEngine engine;

  setUp(() {
    engine = BackgroundPlaybackEngine(
      backend: PlayerBackend.mediaKit,
      attachNative: false,
    );
  });

  tearDown(() => engine.dispose());

  test('a natural end parks the pair with the completion hold set', () {
    engine.debugFireCompleted();

    expect(engine.completionPending, isTrue);
    expect(engine.isPlaying, isFalse);
  });

  test('an explicit pause ends the completion hold', () async {
    engine.debugFireCompleted();

    await engine.pause();

    expect(engine.completionPending, isFalse,
        reason: 'a pause is a definite transport state, not a parked end');
  });

  test('a seek ends the completion hold', () async {
    engine.debugFireCompleted();

    await engine.seek(const Duration(seconds: 5));

    expect(engine.completionPending, isFalse,
        reason: 'a seek means "no longer parked at the end"');
  });

  test('a real play ends the completion hold', () async {
    engine.debugFireCompleted();

    await engine.play();

    expect(engine.completionPending, isFalse);
  });

  test('a stop ends the completion hold', () async {
    engine.debugFireCompleted();

    await engine.stop();

    expect(engine.completionPending, isFalse);
  });
}
