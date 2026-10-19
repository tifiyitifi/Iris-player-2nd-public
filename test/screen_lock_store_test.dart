import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/screen_lock/store/use_screen_lock_store.dart';

/// The screen lock is a transient touch guard. These tests pin the transitions
/// AND the teardown semantics: an armed lock must never survive the session it
/// was armed in.
void main() {
  group('ScreenLockStore', () {
    test('starts unlocked', () {
      final store = ScreenLockStore();
      expect(store.state.locked, isFalse);
    });

    test('lock arms and is idempotent', () {
      final store = ScreenLockStore()
        ..lock()
        ..lock();
      expect(store.state.locked, isTrue);
    });

    test('unlock releases and is idempotent', () {
      final store = ScreenLockStore()
        ..lock()
        ..unlock()
        ..unlock();
      expect(store.state.locked, isFalse);
    });

    test('toggle flips the guard both ways', () {
      final store = ScreenLockStore();
      store.toggle();
      expect(store.state.locked, isTrue);
      store.toggle();
      expect(store.state.locked, isFalse);
    });

    test('reset drops an armed lock (session teardown backstop)', () {
      final store = ScreenLockStore()
        ..lock()
        ..reset();
      expect(store.state.locked, isFalse);
      expect(store.state.uiVisible, isFalse);
    });

    test('lock shows the lock chrome', () {
      final store = ScreenLockStore()..lock();
      expect(store.state.uiVisible, isTrue);
    });

    test('hide/show/toggleLockUi flip only the chrome, never the guard', () {
      final store = ScreenLockStore()..lock();
      store.hideLockUi();
      expect(store.state.uiVisible, isFalse);
      expect(store.state.locked, isTrue);
      store.showLockUi();
      expect(store.state.uiVisible, isTrue);
      store.toggleLockUi();
      expect(store.state.uiVisible, isFalse);
      expect(store.state.locked, isTrue);
    });

    test('unlock drops the chrome with the guard', () {
      final store = ScreenLockStore()
        ..lock()
        ..unlock();
      expect(store.state.locked, isFalse);
      expect(store.state.uiVisible, isFalse);
    });

    test('chrome ops are no-ops while unlocked', () {
      final store = ScreenLockStore()
        ..showLockUi()
        ..toggleLockUi()
        ..hideLockUi();
      expect(store.state.uiVisible, isFalse);
    });
  });
}
