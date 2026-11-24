import 'package:flutter_test/flutter_test.dart';
import 'package:iris/store/use_player_ui_store.dart';

/// The picture-fullscreen queue overlay is TRANSIENT: one seam owns its
/// visibility, so no caller can leave it half-open (peeking cleared while a
/// seed stays on), which is exactly the "opened it and now nothing closes it"
/// state users hit with the old sticky pin.
void main() {
  group('picture-fullscreen queue overlay visibility seam', () {
    late PlayerUiStore store;

    setUp(() {
      store = PlayerUiStore();
    });

    test('seed(reveal: true) starts revealed without a sticky pin', () {
      store.seedFullscreenDockOnEntry(true);
      expect(store.isFullscreenDockShown, isTrue);
      store.hideFullscreenDock();
      expect(store.isFullscreenDockShown, isFalse);
    });

    test('seed(reveal: false) starts hidden (hidePanel)', () {
      store.seedFullscreenDockOnEntry(false);
      expect(store.isFullscreenDockShown, isFalse);
    });

    test('show reveals transiently: peeking on, any seed cleared', () {
      store.seedFullscreenDockOnEntry(true);
      store.showFullscreenDock();
      expect(store.state.isFullscreenDockPeeking, isTrue);
      expect(store.state.isFullscreenDockPinned, isFalse,
          reason: 'a transient reveal must not survive the pointer leaving');
      expect(store.isFullscreenDockShown, isTrue);
    });

    test('hide clears both flags in one write', () {
      store.seedFullscreenDockOnEntry(true);
      store.hideFullscreenDock();
      expect(store.state.isFullscreenDockPinned, isFalse);
      expect(store.state.isFullscreenDockPeeking, isFalse);
    });

    test('hide is idempotent and a no-op when already hidden', () {
      store.hideFullscreenDock();
      expect(store.isFullscreenDockShown, isFalse);
      store.showFullscreenDock();
      store.hideFullscreenDock();
      store.hideFullscreenDock();
      expect(store.isFullscreenDockShown, isFalse);
    });
  });
}
