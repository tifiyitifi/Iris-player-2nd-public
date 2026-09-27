import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/app_startup.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/info.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/pages/bootstrap_gate.dart';
import 'package:iris/pages/home/home.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/theme.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/utils/request_storage_permission.dart';
import 'package:iris/utils/semantics_tree_dumper.dart';
import 'package:media_kit/media_kit.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saf_util/saf_util.dart';

import 'package:iris/globals.dart' as globals;
final areaKeyLog = AreaKeyLog(LogKeys.legacyMain);

/// Test-only seam: widget tests run on a desktop host, so the Windows-only
/// suppression below is unreachable/unbypassable without forcing the flag.
/// Production never writes it; a getter-backed nullable so tests can flip
/// it per-case at runtime (same pattern as
/// `debugIsMobilePlatformOverride`).
bool? debugSuppressWindowsSemanticsOverride;

bool get _suppressWindowsSemantics =>
    debugSuppressWindowsSemanticsOverride ?? isWindows;

/// Windows-only semantics suppression — the AXTree-corruption kill-switch.
///
/// WHY (flutter/flutter #182444 / #190344 / #98099 family — engine-side
/// `ui::AXTree` incremental-update corruption, unfixed as of Flutter
/// 3.44.x): the Windows engine's accessibility bridge keeps its own AXTree
/// cache and applies the framework's semantics DIFFS in two-phase batches
/// ("AXTree cannot move a node in a single update"). Any STRUCTURAL batch —
/// subtree mount/unmount from popup open/close, tab swap, route
/// replacement, conditional unmount — can leave that cache permanently
/// inconsistent. One bad batch makes EVERY subsequent commit fail
/// ("Nodes left pending by the update: N" / "`<id>` will not be in the tree
/// and is not the new root") for the rest of the session, spamming errors
/// at frame rate, with documented native-crash risk (#182444 production
/// report).
///
/// Session evidence (2026-08, .ai_knowledge/tmp/windows_play/*.txt): a
/// legitimate 35-node route-subtree swap seeded the corruption; the next
/// benign update detonated it ("35 will not be in the tree"); the engine
/// then retried the poisoned batch forever while the FRAMEWORK tree stayed
/// correct (39 nodes, byte-identical across periodic dumps). The framework
/// tree is never lost — only the engine-side cache — and Dart has no
/// resync channel for it: replaying updates through the same buggy apply
/// path reproduces the failure, so app-side code cannot guarantee "no node
/// loss". Toggling the screen reader off/on resets it (bridge teardown),
/// which confirms the corruption is engine-cache state, not framework
/// state.
///
/// The only reliable app-side guarantee is an EMPTY semantics tree: the
/// engine receives one valid root-only update and never another.
///
/// Tradeoff (accepted 2026-08): NVDA/Narrator cannot read in-app controls
/// on Windows; the OS window title (windowManager.setTitle: position +
/// queue index + file name) remains the a11y surface, and all keyboard /
/// gesture interaction is unaffected. Other platforms are untouched.
///
/// STATIC wrap from the first frame (not reactive on semanticsEnabled) is
/// deliberate: a mid-session exclude flip would itself be a structural
/// batch and could seed the very corruption this prevents. With semantics
/// disabled (no screen reader attached) ExcludeSemantics has no runtime
/// cost at all.
///
/// REMOVE THIS WRAP when the upstream engine fix ships in stable — it is
/// the single switch that restores Windows in-app accessibility.
Widget wrapPlatformSemantics(BuildContext context, Widget? child) {
  if (!_suppressWindowsSemantics || child == null) {
    return child ?? const SizedBox.shrink();
  }
  return ExcludeSemantics(child: child);
}

void main(List<String> arguments) async {
  areaKeyLog.i('arguments: $arguments');
  globals.arguments = arguments;

  WidgetsFlutterBinding.ensureInitialized();

  // AXTree-diag: log whether the Windows UIA bridge is active at startup.
  // This directly tells us whether the engine's accessibility tree is being
  // built (errors only occur when true). Also watch for changes.
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  areaKeyLog.i('AXTree-diag semanticsEnabled=${dispatcher.semanticsEnabled}');
  final prevSemanticsCallback = dispatcher.onSemanticsEnabledChanged;
  dispatcher.onSemanticsEnabledChanged = () {
    prevSemanticsCallback?.call();
    areaKeyLog.i(
        'AXTree-diag semanticsEnabledChanged=${dispatcher.semanticsEnabled}');
    if (axtreeDiagLogsEnabled && dispatcher.semanticsEnabled) {
      // First frame after enabling has no tree yet; dump on the next cycle.
      Future<void>.delayed(const Duration(milliseconds: 500), () {
        SemanticsTreeDumper.dumpOnce('semantics-enabled');
      });
    }
  };
  // AXTree-diag: periodic framework semantics-tree dump + per-frame diff so
  // engine-side "Failed to update ui::AXTree" ids (#182444/#190344) can be
  // mapped to widgets (rect + label + parent chain) and the residual
  // high-frequency emitters / structural corruption triggers can be pinned.
  if (kDebugMode && axtreeDiagLogsEnabled) {
    SemanticsTreeDumper.startPeriodic();
    SemanticsTreeDumper.startFrameDiffWatcher();
  }
  // FrameTiming diag: periodic build/raster averages (profile-mode jank baseline).
  // Keep lightweight; removed after verification.
  int frameCount = 0;
  Duration totalBuild = Duration.zero;
  Duration totalRaster = Duration.zero;
  Duration totalVsyncOverhead = Duration.zero;
  DateTime lastLog = DateTime.now();
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      totalBuild += t.buildDuration;
      totalRaster += t.rasterDuration;
      totalVsyncOverhead += t.vsyncOverhead;
    }
    frameCount += timings.length;
    final now = DateTime.now();
    if (now.difference(lastLog).inSeconds >= 3 && frameCount > 0) {
      final avgBuildUs = totalBuild.inMicroseconds ~/ frameCount;
      final avgRasterUs = totalRaster.inMicroseconds ~/ frameCount;
      final avgVsyncUs = totalVsyncOverhead.inMicroseconds ~/ frameCount;
      areaKeyLog.i(
          'AXTree-diag frameTiming frames=$frameCount avgBuild=${avgBuildUs}us avgRaster=${avgRasterUs}us avgVsyncOverhead=${avgVsyncUs}us');
      frameCount = 0;
      totalBuild = Duration.zero;
      totalRaster = Duration.zero;
      totalVsyncOverhead = Duration.zero;
      lastLog = now;
    }
  });

  MediaKit.ensureInitialized();

  // Portable-mode decision MUST precede any database / store initialization:
  // it relocates the Drift file and selects the KV backend.
  await AppPaths.init();

  if (isDesktop) {
    await windowManagerEnsureReady();
  }

  // Player immersive mode: hidden bars, edge-swipe to reveal, auto-hide.
  // Mobile-only (desktop fullscreen is window_manager's job). The soft keyboard
  // forces the bars visible; `useImmersiveRearm` re-arms immersion once it
  // closes (flutter/flutter #89780).
  if (isAndroid) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  runApp(const StoreScope(child: MyApp()));
}


class MyApp extends HookWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    useEffect(() {
      () async {
        globals.storagePermissionStatus = Platform.isAndroid
            ? await isAndroid11OrHigher()
                ? await Permission.manageExternalStorage.status
                : await Permission.storage.status
            : PermissionStatus.granted;
      }();
      return null;
    }, []);

    ThemeMode themeMode = useAppStore().select(context, (state) => state.themeMode);
    String language = useAppStore().select(context, (state) => state.language);

    final appLinks = useMemoized(() => AppLinks());
    final String? uri = useStream(appLinks.stringLinkStream).data;

    useEffect(() {
      () async {
        if (uri != null && globals.initUri != uri) {
          areaKeyLog.i('Uri: $uri');
          if (Platform.isAndroid) {
            final file = await SafUtil().documentFileFromUri(uri, false);
            if (file != null) {
              await useAppStore().updateAutoPlay(true);
              PlaybackProviderRegistry.beginExternalFeed();
              await usePlayQueueStore().update(
                playQueue: [
                  PlayQueueItem(
                    file: FileItem(
                      name: file.name,
                      uri: file.uri,
                      size: file.length,
                    ),
                    index: 0,
                  ),
                ],
                index: 0,
              );
            }
          }
        }
      }();
      return null;
    }, [uri]);

    return DynamicColorBuilder(builder: (
      ColorScheme? lightDynamic,
      ColorScheme? darkDynamic,
    ) {
      final theme = getTheme(
        context: context,
        lightDynamic: lightDynamic,
        darkDynamic: darkDynamic,
      );

      return MaterialApp(
        title: INFO.title,
        theme: theme.light,
        darkTheme: theme.dark,
        themeMode: themeMode,
        // AXTree-corruption kill-switch — see wrapPlatformSemantics.
        builder: wrapPlatformSemantics,
        home: const BootstrapGate(child: Home()),
        locale: language == 'system' || language == 'auto' ? null : Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        localeResolutionCallback: (locale, supportedLocales) =>
            supportedLocales.map((e) => e.languageCode).toList().contains(locale!.languageCode)
                ? null
                : const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
      );
    });
  }
}
