import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/view/update_flow.dart';
import 'package:iris/info.dart';
import 'package:iris/models/db/app_database_holder.dart';
import 'package:iris/utils/get_latest_release.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/utils/url.dart';
import 'package:iris/widgets/dialogs/show_app_overview_dialog.dart';
import 'package:iris/widgets/dialogs/show_data_storage_info_dialog.dart';
import 'package:iris/widgets/dialogs/show_known_issues_dialog.dart';
import 'package:iris/widgets/dialogs/show_release_dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

bool isMsix() {
  if (!isWindows) {
    return false;
  }
  String resolvedExecutablePath = Platform.resolvedExecutable;
  String path = p.dirname(resolvedExecutablePath);
  String manifestPath = p.join(path, 'AppxManifest.xml');
  return File(manifestPath).existsSync();
}

/// 二开构建开关：恒为 false。本 fork 在 About 页隐藏作者名与上游仓库入口。
/// 尽管恒为 false，禁止删除下面的隐藏分支代码——作为兼容保留；改回 true
/// 可恢复上游 About 入口（含检查更新 / 源码 / 作者）。
const bool kShowUpstreamAboutEntries = false;

/// 暂不支持版本更新跳转功能。设置为 true 可恢复跳转。
const bool kEnableVersionUpdate = false;

class About extends HookWidget {
  const About({super.key});

  static const title = 'About';

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final packageInfo = useState<PackageInfo?>(null);
    final noNewVersion = useState(false);

    // Asked once: the packaging of a build cannot change while the app runs,
    // and a disk call has no business in `build`.
    final msix = useMemoized(isMsix);

    useEffect(() {
      void getPackageInfo() async => packageInfo.value = await PackageInfo.fromPlatform();

      getPackageInfo();
      return null;
    }, []);

    return SingleChildScrollView(
      child: Column(
        children: [
          ListTile(
            leading: Image.asset('assets/images/logo.png', width: 24, height: 24),
            title: const Text(INFO.title),
            subtitle: Text(t.app_description),
          ),
          ListTile(
            leading: const Icon(Icons.info_rounded),
            title: Text(t.version),
            subtitle: Text(packageInfo.value != null ? packageInfo.value!.version : ''),
            // 暂不支持版本更新功能
            onTap: kEnableVersionUpdate
                ? () => launchURL(
                    '${INFO.githubUrl}/releases/tag/v${packageInfo.value?.version}')
                : null,
          ),
          // Manual entry for the first-launch feature tour; always opens
          // regardless of the suppression flag.
          ListTile(
            leading: const Icon(Icons.explore_rounded),
            title: Text(t.app_overview_about_tile_title),
            subtitle: Text(t.app_overview_about_tile_sub),
            onTap: () => showAppOverviewDialog(context),
          ),
          // Manual update check. There is no startup poll: a slow or blocked
          // network must never delay the app, so a check only runs when the
          // user asks for one.
          //
          // A Microsoft Store package is sandboxed (its binaries live in the
          // read-only WindowsApps folder) and its .msix is not published to the
          // release, so it can neither self-update nor be replaced by a
          // download. Offering the row there would be a dead end, so it is
          // hidden outright. A platform the updater cannot serve is the same
          // dead end, and it is hidden the same way rather than shown and then
          // told it has nothing to offer.
          if (!msix && currentUpdatePlatform() != UpdatePlatform.unsupported)
            ListTile(
              leading: const Icon(Icons.update_rounded),
              title: Text(t.check_update),
              subtitle: Text(t.check_update_note),
              onTap: () => runUpdateCheckFlow(context),
            ),
          // 恒为 false：作者名与上游仓库入口（检查更新 / 源码 / 作者）
          // 在此隐藏。禁止删除本分支代码——作为兼容保留；改回 true
          // 可恢复上游 About 入口。
          if (kShowUpstreamAboutEntries) ...[
            ListTile(
                leading: const Icon(Icons.update_rounded),
                title: Text(t.check_update),
                subtitle: noNewVersion.value ? Text(t.no_new_version) : null,
                onTap: () async {
                  if (isMsix()) {
                    launchURL('ms-windows-store://pdp/?ProductId=${INFO.msStoreId}');
                    return;
                  }
                  noNewVersion.value = false;
                  final release = await getLatestRelease();
                  if (release != null && context.mounted) {
                    showReleaseDialog(context, release: release);
                  } else {
                    noNewVersion.value = true;
                  }
                }),
            ListTile(
              leading: const Icon(Icons.code_rounded),
              title: Text(t.source_code),
              subtitle: const Text(INFO.githubUrl),
              onTap: () => launchURL(INFO.githubUrl),
            ),
            ListTile(
              leading: const Icon(Icons.person_rounded),
              title: Text(t.author),
              subtitle: const Text(INFO.author),
              onTap: () => launchURL(INFO.authorUrl),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.storage_rounded),
            title: Text(t.database_inspector),
            subtitle: Text(t.database_inspector_description),
            onTap: () => AppDatabaseHolder.openInspector(context),
          ),
          // Static explainer (localized; dialog body carries the details).
          ListTile(
            leading: const Icon(Icons.enhanced_encryption_outlined),
            title: Text(t.set_storage_info_title),
            subtitle: Text(t.set_storage_info_sub),
            onTap: () => showDataStorageInfoDialog(context),
          ),
          // Known-issues list (localized; every platform shows every entry).
          ListTile(
            leading: const Icon(Icons.bug_report_rounded),
            title: Text(t.known_issues_title),
            subtitle: Text(t.known_issues_sub),
            onTap: () => showKnownIssuesDialog(context),
          ),
        ],
      ),
    );
  }
}
