import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/app_identity/model/domain/app_identity_entry.dart';
import 'package:iris/features/app_identity/services/app_identity_facade.dart';
import 'package:iris/features/app_identity/services/pinned_refresh_policy.dart';
import 'package:iris/features/app_identity/services/shortcut_channel_service.dart';
import 'package:iris/features/app_identity/store/use_app_identity_store.dart';
import 'package:iris/features/app_identity/view/app_identity_manager_dialog.dart'
    show EntryAvatar, AppIdentityImageFile, openAppIdentityEditor;
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/a11y_tooltip.dart';

Future<void> showAppIdentityManager(BuildContext context) {
  return showPopup(
    context: context,
    direction: PopupDirection.right,
    child: const AppIdentityManagerPage(),
  );
}

class AppIdentityManagerPage extends HookWidget {
  const AppIdentityManagerPage({
    super.key,
    this.pinnedRefreshThrottle = const Duration(
      milliseconds: PinnedRefreshPolicy.throttleMs,
    ),
    this.queryPinned,
    this.isAndroidOverride,
  });

  /// Minimum interval between two resume-triggered platform queries.
  /// Zero in widget tests so every resume is observable.
  final Duration pinnedRefreshThrottle;

  /// Test seam for the platform query; production uses the MethodChannel.
  final Future<Set<String>> Function()? queryPinned;

  /// Test seam for the Android guard; production reads `Platform.isAndroid`.
  final bool? isAndroidOverride;

  @override
  Widget build(BuildContext context) {
    final store = useAppIdentityStore();
    final entries = store.select(context, (s) => s.entries);
    final activeId = store.select(context, (s) => s.activeEntryId);
    final pinnedIds = useState<Set<String>>(const {});
    final refreshing = useState(false);
    final lastQueryMs = useRef(0);
    final lifecycle = useAppLifecycleState();

    // The pinned badge lives outside the store (launcher-owned state reached
    // over a Binder channel), so it is refreshed on explicit events only —
    // never polled. [force] bypasses the throttle for explicit user actions
    // (manual refresh, editor return, regenerate); mount and resume share
    // the throttled path.
    Future<void> refreshPinned({bool force = false}) async {
      if (refreshing.value) return;
      final route = ModalRoute.of(context);
      if (!PinnedRefreshPolicy.shouldQuery(
        isRefreshing: refreshing.value,
        isAndroid: isAndroidOverride ?? Platform.isAndroid,
        isRouteCurrent: route == null || route.isCurrent,
        hasEntries: store.state.entries.isNotEmpty,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        lastQueryMs: lastQueryMs.value,
        force: force,
        throttleMs: pinnedRefreshThrottle.inMilliseconds,
      )) {
        return;
      }
      refreshing.value = true;
      try {
        final query = queryPinned ?? ShortcutChannelService().queryPinned;
        final next = await query();
        lastQueryMs.value = DateTime.now().millisecondsSinceEpoch;
        if (!context.mounted) return;
        // Same ids → skip setState so a no-change resume costs zero rebuilds.
        if (PinnedRefreshPolicy.isSameSet(next, pinnedIds.value)) return;
        pinnedIds.value = next;
      } finally {
        if (context.mounted) refreshing.value = false;
      }
    }

    // Mount and resume share the non-forced path: the two post-frame
    // callbacks below run back-to-back, so the first one to run holds
    // `refreshing` (or refreshes `lastQueryMs`) and the other becomes a
    // no-op — exactly one platform query per mount in every interleaving.
    // Forced (manual refresh, editor return, regenerate) bypasses that.
    void scheduleRefresh() {
      // Deferred past the current build/init: ModalRoute is not listable
      // from HookState.initState, where mount effects run synchronously.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        unawaited(refreshPinned());
      });
    }

    useEffect(() {
      scheduleRefresh();
      return null;
    }, []);

    // Pinning happens on the launcher (the system confirmation UI
    // backgrounds the app), so returning to the foreground must re-query.
    useEffect(() {
      if (lifecycle != AppLifecycleState.resumed) return null;
      scheduleRefresh();
      return null;
    }, [lifecycle]);

    // Creating/editing may end with a launcher pin confirmation behind this
    // page; always re-query on return so the badge tracks it immediately.
    Future<void> openEditorAndRefresh([AppIdentityEntry? existing]) async {
      await openAppIdentityEditor(context, existing: existing);
      if (!context.mounted) return;
      await refreshPinned(force: true);
    }

    Future<void> regenerate(AppIdentityEntry e) async {
      final png = await AppIdentityImageFile.readIconPng(e.imageRef);
      if (!context.mounted) return;
      if (png == null) {
        // The prepared icon is gone (or was never set): there is nothing to
        // (re)pin. Ask for a new image instead of reporting a success that
        // leaves the home screen without an icon.
        await _errorDialog(
          Navigator.of(context),
          getLocalizations(context).entry_icon_missing,
        );
        if (!context.mounted) return;
        await openEditorAndRefresh(e);
        return;
      }
      final failure =
          await applyEntryToPlatform(e, png, getLocalizations(context));
      if (!context.mounted) return;
      if (failure != null) {
        await _errorDialog(Navigator.of(context), failure);
      }
      await refreshPinned(force: true);
    }

    Future<void> confirmDelete(AppIdentityEntry e) async {
      final t = getLocalizations(context);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.entry_delete_title),
          content: Text(t.entry_delete_body(e.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.remove),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await AppIdentityStore.deleteFilesFor(e);
      await useAppIdentityStore().deleteEntry(e.id);
      // Independent entries own a workspace row — remove it alongside so the
      // database does not accumulate stranded queues.
      final wsId = e.workspaceScenarioId;
      if (wsId != null && wsId.isNotEmpty) {
        try {
          await usePlaybackScenarioStore().deleteEntryWorkspace(wsId);
        } catch (_) {
          // Best-effort: a leftover workspace row is harmless clutter.
        }
      }
      // The paired 副音 workspace dies with the entry too.
      final bgWsId = e.backgroundWorkspaceScenarioId;
      if (bgWsId != null && bgWsId.isNotEmpty) {
        try {
          await usePlaybackScenarioStore().deleteEntryBackgroundWorkspace(bgWsId);
        } catch (_) {
          // Best-effort: a leftover background row is harmless clutter.
        }
      }
      await removePlatformArtifacts(e);
      // The card is gone; drop its badge locally instead of a fresh query.
      if (pinnedIds.value.contains(e.id)) {
        pinnedIds.value = {...pinnedIds.value}..remove(e.id);
      }
    }

    return Column(
      children: [
        _Header(
          refreshing: refreshing.value,
          onRefresh: () => refreshPinned(force: true),
          onClose: () => Navigator.of(context).pop(),
        ),
        Divider(
          height: 0,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
        ),
        Expanded(
          child: entries.isEmpty
              ? _EmptyState(onCreate: () => openEditorAndRefresh())
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    final pinned = pinnedIds.value.contains(e.id);
                    final isActive = activeId == e.id;
                    return _EntryCard(
                      entry: e,
                      pinned: pinned,
                      isActive: isActive,
                      onRegenerate: () => regenerate(e),
                      onEdit: () => openEditorAndRefresh(e),
                      onDelete: () => confirmDelete(e),
                    );
                  },
                ),
        ),
        Divider(
          height: 0,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
        ),
        _BottomBar(onNewEntry: () => openEditorAndRefresh()),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.refreshing,
    required this.onRefresh,
    required this.onClose,
  });

  final bool refreshing;
  final Future<void> Function() onRefresh;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              t.entry_title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: t.entry_check_pinned,
            onPressed: refreshing ? null : onRefresh,
            icon: refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          a11yTooltipIconButton(
            context: context,
            tooltip: t.entry_close_esc,
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.onNewEntry});

  final VoidCallback onNewEntry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: onNewEntry,
              icon: const Icon(Icons.add_rounded),
              label: Text(getLocalizations(context).entry_new_short),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.layers_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              t.entry_empty_title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              t.entry_empty_body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.entry_new_short),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.pinned,
    required this.isActive,
    required this.onRegenerate,
    required this.onEdit,
    required this.onDelete,
  });

  final AppIdentityEntry entry;
  final bool pinned;
  final bool isActive;
  final VoidCallback onRegenerate;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final scheme = Theme.of(context).colorScheme;
    final borderColor = pinned ? scheme.outlineVariant : scheme.outline.withValues(alpha: 0.6);
    final card = Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: pinned ? 0.35 : 0.22),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderColor, width: pinned ? 1 : 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isActive)
            Container(
              width: 3,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                ),
              ),
            ),
          if (isActive) const SizedBox(width: 9) else const SizedBox(width: 12),
          EntryAvatar(
            imageRef: entry.imageRef,
            sourcePath: entry.sourcePath,
            size: 56,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 10, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isActive)
                        a11yTooltip(
                          context: context,
                          message: t.entry_active,
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: scheme.primary,
                            size: 18,
                          ),
                        ),
                      const SizedBox(width: 6),
                      _PinStatusChip(pinned: pinned),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _StateChips(entry: entry),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (!pinned)
                        FilledButton.tonalIcon(
                          onPressed: onRegenerate,
                          icon: const Icon(Icons.link_rounded, size: 16),
                          label: Text(t.entry_regenerate),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: Text(t.entry_edit_short),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: Text(t.entry_delete_short),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          foregroundColor: scheme.error,
                          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    if (!pinned) {
      return Opacity(opacity: 0.88, child: card);
    }
    return card;
  }
}

class _StateChips extends StatelessWidget {
  const _StateChips({required this.entry});

  final AppIdentityEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final scheme = Theme.of(context).colorScheme;
    if (entry.sharedWithDefault) {
      return _MiniChip(
        icon: Icons.link_rounded,
        label: t.entry_shared_default,
        color: scheme.primary,
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _MiniChip(
          icon: Icons.call_split_rounded,
          label: t.entry_independent,
          color: scheme.tertiary,
        ),
        if (entry.seedScenarioId != null)
          _MiniChip(
            icon: Icons.movie_filter_outlined,
            label: t.entry_chip_scenario,
            color: scheme.primary,
          ),
        if (entry.seedTagId != null)
          _MiniChip(
            icon: Icons.label_outline,
            label: t.entry_chip_tag,
            color: scheme.secondary,
          ),
      ],
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

class _PinStatusChip extends StatelessWidget {
  const _PinStatusChip({required this.pinned});

  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (pinned) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 12, color: Colors.green),
            const SizedBox(width: 4),
            Text(getLocalizations(context).entry_pinned, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.green)),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_off_rounded, size: 12, color: scheme.error),
          const SizedBox(width: 4),
          Text('OFF', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.error)),
        ],
      ),
    );
  }
}

Future<void> _errorDialog(NavigatorState navigator, String message) {
  return showDialog<void>(
    context: navigator.context,
    builder: (ctx) => AlertDialog(
      title: Text(getLocalizations(ctx).entry_title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(getLocalizations(ctx).ok),
        ),
      ],
    ),
  );
}
