import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/fake_cut/view/fake_cut_tab.dart';
import 'package:iris/models/player.dart';
import 'package:iris/widgets/popups/track/audio_track_list.dart';
import 'package:iris/widgets/popups/track/subtitle_list.dart';
import 'package:iris/widgets/popups/track/sync_adjust_bar.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:provider/provider.dart';

class ITab {
  final String title;
  final Widget child;

  const ITab({
    required this.title,
    required this.child,
  });
}

class SubtitleAndAudioTrack extends HookWidget {
  const SubtitleAndAudioTrack({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final player = Provider.of<MediaPlayer>(context);

    List<ITab> tabs = [
      ITab(title: t.subtitle, child: SubtitleList()),
      ITab(title: t.audio_track, child: AudioTrackList()),
      // 简播 is mpv-EDL only: the tab is absent on fvp rather than offering a
      // half-working feature (see fake_cut_preflight.dart).
      if (player is MediaKitPlayer)
        ITab(title: t.fake_cut, child: const FakeCutTab()),
    ];

    final tabController = useTabController(initialLength: tabs.length);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: TabBarView(
            controller: tabController,
            children: tabs
                .map((e) => Card(
                      color: Colors.transparent,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: e.child,
                    ))
                .toList(),
          ),
        ),
        // Sync nudges — mediaKit only (capability hides it elsewhere).
        if (player.supportsSyncAdjustment)
          SyncAdjustBar(player: player),
        Divider(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
          height: 0,
        ),
        Container(
          padding: EdgeInsets.zero,
          child: Container(
            padding: const EdgeInsets.fromLTRB(0, 0, 4, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                TabBar(
                    controller: tabController,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    dividerColor: Colors.transparent,
                    tabs: tabs.map((tab) => Tab(text: tab.title)).toList()),
                const Spacer(),
                IconButton(
                  tooltip: '${t.close} ( Escape )',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
