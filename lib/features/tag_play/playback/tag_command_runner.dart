import 'package:iris/features/scenario_playback/playback/playback_provider.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/domain/tag_command.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_ordering.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_tag.dart';
import 'package:iris/features/tag_play/playback/tag_play_controller.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.tagPlay);

/// What a run actually did, so the sheet can reflect it without re-reading
/// the database (membership rows update in place — the list stays snappy).
class TagCommandOutcome {
  const TagCommandOutcome({
    this.appliedTagIds = const <int>[],
    this.appliedOrdinals = const <int>[],
    this.unknownOrdinals = const <int>[],
    this.noCurrentFile = false,
    this.viewSwitchingUnavailable = false,
    this.emptyView = false,
    this.playedNoTag = false,
    this.bookmarkLost = false,
  });

  /// Tags the command actually touched (add/remove membership, or play).
  final List<int> appliedTagIds;

  /// The 1-based ordinals those tags correspond to.
  final List<int> appliedOrdinals;

  /// Ordinals that named no tag (out of range for the current display order).
  final List<int> unknownOrdinals;

  /// add/remove against a queue whose current item cannot be tagged.
  final bool noCurrentFile;

  /// `*` while the scenario-driven playback path is unavailable.
  final bool viewSwitchingUnavailable;

  /// `*N` aimed at a tag whose view has no media — nothing to jump to.
  final bool emptyView;

  /// `*0` — playback handed back to the original (untagged) list.
  final bool playedNoTag;

  /// `*N` entered a tag whose stored bookmark file no longer exists: the view
  /// is shown but nothing auto-plays. The sheet reports it and Play starts from
  /// the top.
  final bool bookmarkLost;
}

/// Executes a parsed [TagCommand] against the live tags, the current queue
/// item and the tag view switcher.
///
/// Sits where the old numpad chord controller did, but takes the command as
/// data: the input bar and the keyboard entry keys share this one path, so
/// ordinal resolution (sheet display order, pins first) stays identical to
/// the badge numbering.
class TagCommandRunner {
  TagCommandRunner({
    TagPlayRepository? repo,
    TagPlayController? viewSwitcher,
  })  : _repoOverride = repo,
        _viewSwitcherOverride = viewSwitcher;

  final TagPlayRepository? _repoOverride;
  final TagPlayController? _viewSwitcherOverride;

  TagPlayRepository get _repo => _repoOverride ?? DbModule.tagPlayRepo;
  TagPlayController get _switcher =>
      _viewSwitcherOverride ?? PlaybackProviderRegistry.tagPlay;

  Future<TagCommandOutcome> run(TagCommand command) async {
    if (command.kind == TagCommandKind.play &&
        !TagPlayGate.viewSwitchingEnabled) {
      return const TagCommandOutcome(viewSwitchingUnavailable: true);
    }

    final List<TagPlayTag> ordered;
    try {
      final tags = await _repo.tags();
      ordered = tagPlayDisplayOrder(tags, useTagPlayStore().state.pinnedTagIds);
    } catch (e) {
      _log.e('tag command: resolving tags failed: $e');
      return const TagCommandOutcome();
    }

    final unknown = <int>[];
    final resolved = <(int ordinal, TagPlayTag tag)>[];
    for (final ordinal in command.ordinals) {
      // `*0` is the no-tag target, not an ordinal — never an out-of-range hit.
      if (command.kind == TagCommandKind.play &&
          ordinal == kTagCommandNoTagOrdinal) {
        continue;
      }
      if (ordinal < 1 || ordinal > ordered.length) {
        unknown.add(ordinal);
        continue;
      }
      resolved.add((ordinal, ordered[ordinal - 1]));
    }

    switch (command.kind) {
      case TagCommandKind.play:
        if (command.ordinals.contains(kTagCommandNoTagOrdinal)) {
          // Hand playback back to the original (untagged) list — a no-op when
          // no tag view is active, which is already the wanted state.
          try {
            await _switcher.exitToNoTag();
          } catch (e) {
            _log.e('tag command: exitToNoTag failed: $e');
            return const TagCommandOutcome();
          }
          return TagCommandOutcome(
            playedNoTag: true,
            unknownOrdinals: unknown,
          );
        }
        if (resolved.isEmpty) {
          return TagCommandOutcome(unknownOrdinals: unknown);
        }
        final target = resolved.first;
        final PlaybackEntry? started;
        try {
          started = await _switcher.enterView(target.$2.id);
        } catch (e) {
          _log.e('tag command: enterView failed: $e');
          return TagCommandOutcome(unknownOrdinals: unknown);
        }
        // A null entry means the tag's view could not start: either it resolved
        // empty (no media in this scenario / no members) or its bookmark file
        // is gone (the view is shown but nothing auto-plays).
        if (started == null) {
          final lost = _switcher.isBookmarkLost;
          return TagCommandOutcome(
            unknownOrdinals: unknown,
            emptyView: !lost,
            bookmarkLost: lost,
          );
        }
        return TagCommandOutcome(
          appliedTagIds: [target.$2.id],
          appliedOrdinals: [target.$1],
          unknownOrdinals: unknown,
        );

      case TagCommandKind.add:
      case TagCommandKind.remove:
        // `+0` / `-0` target every tag, numbered in sheet display order.
        final targets = command.allTags
            ? <(int, TagPlayTag)>[
                for (var i = 0; i < ordered.length; i++) (i + 1, ordered[i]),
              ]
            : resolved;
        if (targets.isEmpty) {
          return TagCommandOutcome(unknownOrdinals: unknown);
        }
        final file = await usePlayQueueStore().getCurrentFile();
        if (file.storageId.isEmpty || file.path.isEmpty) {
          return TagCommandOutcome(
            unknownOrdinals: unknown,
            noCurrentFile: true,
          );
        }
        final appliedIds = <int>[];
        final appliedOrdinals = <int>[];
        for (final entry in targets) {
          try {
            if (command.kind == TagCommandKind.add) {
              await _repo.addMember(
                tagId: entry.$2.id,
                storageId: file.storageId,
                pathSegments: file.path,
              );
            } else {
              await _repo.removeMember(
                tagId: entry.$2.id,
                storageId: file.storageId,
                pathSegments: file.path,
              );
            }
            appliedIds.add(entry.$2.id);
            appliedOrdinals.add(entry.$1);
          } catch (e) {
            _log.e('tag command: ${command.kind.name} failed: $e');
          }
        }
        // Keep the live view consistent when a mutated tag drives it.
        if (appliedIds.isNotEmpty && _switcher.isActive) {
          try {
            await _switcher.revalidate();
          } catch (e) {
            _log.e('tag command: revalidate failed: $e');
          }
        }
        return TagCommandOutcome(
          appliedTagIds: appliedIds,
          appliedOrdinals: appliedOrdinals,
          unknownOrdinals: unknown,
        );
    }
  }
}
