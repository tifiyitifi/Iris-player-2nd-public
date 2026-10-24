import 'package:flutter_test/flutter_test.dart';
import 'package:iris/store/kv/kv_keys.dart';

/// Every persisted KV key must be classified as shared or per-window session
/// state: an unclassified key is how "two windows fight over one value" bugs
/// creep back in.
void main() {
  test('every migratable key declares a scope', () {
    for (final key in KvKeys.all) {
      expect(KvKeys.scopes.containsKey(key), isTrue,
          reason: '"$key" has no KvScope — add it to KvKeys.scopes');
    }
  });

  test('the scope table lists only known keys', () {
    for (final key in KvKeys.scopes.keys) {
      expect(
        KvKeys.all.contains(key) || KvKeys.secretKeys.contains(key),
        isTrue,
        reason: '"$key" is scoped but is neither a migratable nor a secret key',
      );
    }
  });

  test('internal markers stay out of the scope table', () {
    expect(KvKeys.scopes.containsKey(KvKeys.internalImportDone), isFalse);
    expect(KvKeys.scopes.containsKey(KvKeys.internalImportSkipped), isFalse);
  });

  test('app-wide settings and credentials are shared', () {
    expect(KvKeys.scopes[KvKeys.appState], KvScope.shared);
    expect(KvKeys.scopes[KvKeys.storageState], KvScope.shared);
    expect(KvKeys.scopes[KvKeys.controlGroupState], KvScope.shared);
  });

  test('session state is per window', () {
    for (final key in const [
      KvKeys.playQueueState,
      KvKeys.queryPlayQueueState,
      KvKeys.historyState,
      KvKeys.playbackScenarioActiveId,
      KvKeys.mediaLibContentState,
      KvKeys.mediaLibsPageState,
      KvKeys.mediaLibSelection,
      KvKeys.mediaLibSearchState,
      KvKeys.recursiveScanState,
      KvKeys.playbackScenariosSelection,
      KvKeys.navigationState,
      KvKeys.workspaceClaims,
      KvKeys.backgroundPlaybackPosition,
    ]) {
      expect(KvKeys.scopes[key], KvScope.session, reason: key);
    }
  });

  test('a session key never holds credentials', () {
    for (final entry in KvKeys.scopes.entries) {
      if (entry.value != KvScope.session) continue;
      expect(KvKeys.secretKeys.contains(entry.key), isFalse, reason: entry.key);
    }
  });
}
