import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/update_downloader.dart';
import 'package:iris/features/app_update/view/show_update_result_dialog.dart';
import 'package:iris/utils/file_size_convert.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/widgets/dialogs/delayed_progress_gate.dart';

final _log = AreaKeyLog(LogKeys.appUpdate);

/// [downloadAsset] behind a seam, so the surface contract below is exercisable
/// without a network.
typedef AssetDownloader = Future<File> Function({
  required ReleaseAsset asset,
  String? expectedSha256,
  void Function(DownloadProgress)? onProgress,
  void Function(void Function() abort)? onAbort,
});

/// One package transfer, with the window that reports it.
///
/// Owns the whole contract in one place, so the flow cannot drift away from
/// what the user is actually shown:
///
///  * a transfer that settles inside the delay never opens a window at all;
///  * the window closes on **every** outcome — success, failure and a
///    deliberate cancel — because a dialog nothing pops is a window that never
///    goes away, and awaiting its route never returns;
///  * cancel means cancel: the transfer is aborted, its late completion is
///    dropped and deleted, and nothing is installed and nothing is reported.
///    Without that, a "cancelled" 186 MB download used to finish in the
///    background and hand its package to the installer on its own;
///  * a caller that stopped wanting the run is treated the same way: nothing is
///    installed, nothing is reported, and the package it verified is deleted.
///    Closing the window is an animation, so that interest can evaporate inside
///    it — a back press or an Esc landing between the pop and the return, which
///    is long after the cancel flag is read. [stillWanted] is therefore
///    consulted at both ends of the close, never once;
///  * a failure takes over the same window instead of stacking a second one on
///    top of it, so a broken transfer reads as one continuous dialog.
///
/// [run] releases the window and the progress state itself; the caller only has
/// to read [cancelled] before acting on what it returns.
class GatedUpdateDownload {
  GatedUpdateDownload({
    required this.asset,
    this.expectedSha256,
    this.notice,
    this.downloader = downloadAsset,
    this.stillWanted,
  }) : _gate = DelayedProgressGate(barrierDismissible: false);

  final ReleaseAsset asset;
  final String? expectedSha256;

  /// A line shown under the progress text, for something the reader has to know
  /// while the transfer runs (today: the release published no checksum index, so
  /// the digest check is not happening). Already localized by the caller.
  final String? notice;

  final AssetDownloader downloader;

  /// Whether the caller can still use what this run produces, asked at the two
  /// moments a package is about to be handed over.
  ///
  /// The flow answers it with the caller's `mounted`, so a caller whose own
  /// surface is gone mid-transfer ends the run here instead of silently
  /// abandoning a verified package on disk. Read as late as the hand-over: the
  /// answer can change while the progress window is closing.
  final bool Function()? stillWanted;

  final DelayedProgressGate _gate;
  final ValueNotifier<DownloadProgress> _progress =
      ValueNotifier<DownloadProgress>((received: 0, total: 0));

  /// True once the user backed out of this transfer.
  bool get cancelled => _cancelled;
  bool _cancelled = false;

  /// Set before any pop this class initiates, so a dismissal that arrives as a
  /// consequence of closing the window is not mistaken for the user closing it.
  bool _closing = false;

  /// The transfer's own abort handle, valid from the moment it registers one.
  void Function()? _abort;

  /// Runs the transfer behind its progress window.
  ///
  /// Returns the verified package, or null when the transfer failed (after
  /// reporting it on the same window), the user cancelled, or [stillWanted]
  /// gave up on the run — the last two after deleting what they verified.
  ///
  /// [navigator] must be the ROOT navigator, captured before the caller's first
  /// await: the window has to sit above the route that hosts the caller.
  Future<File?> run({required NavigatorState navigator}) async {
    _gate.arm(navigator: navigator, builder: _buildProgress);
    File? file;
    Object? failure;
    try {
      try {
        file = await downloader(
          asset: asset,
          expectedSha256: expectedSha256,
          onProgress: (value) {
            // A late chunk after the user gave up must not touch state the
            // window no longer shows.
            if (_cancelled) return;
            _progress.value = value;
          },
          onAbort: (abort) {
            _abort = abort;
            // Cancelling during the connect, before the transfer could hand
            // over a handle, still ends it.
            if (_cancelled) abort();
          },
        );
      } catch (error) {
        failure = error;
      }
      return await _settle(file: file, failure: failure);
    } finally {
      // Reached only after the transfer has settled, so no late progress
      // callback can write into a released notifier, and the window's own
      // teardown is allowed to unregister from one.
      _progress.dispose();
      _gate.dispose();
    }
  }

  /// Stops the transfer. Idempotent, and safe to call before the transfer has
  /// registered its abort handle.
  void stop() {
    if (_cancelled) return;
    _cancelled = true;
    _abort?.call();
  }

  Future<File?> _settle({File? file, Object? failure}) async {
    // From here on every pop is ours. A dismissal the transfer still has to
    // answer for can only be the user's, which is what makes the difference
    // between a cancelled run and a successful one.
    _closing = true;
    if (_cancelled) {
      // The user already said no: the window goes first and unconditionally, so
      // nothing the late cleanup below can do leaves this class to release a
      // gate that never had a terminal call.
      await _gate.succeed();
      // Report nothing, install nothing, and drop a package the transfer may
      // have finished writing on its way out.
      _log.i('update download cancelled');
      if (file != null) await discardDownload(file);
      return null;
    }
    if (_abandoned) {
      // Same verdict, quieter reason: there is nobody left to install through,
      // so the run reports nothing and takes the package with it.
      await _gate.succeed();
      _log.i('update download dropped: the caller went away');
      if (file != null) await discardDownload(file);
      return null;
    }
    if (failure != null || file == null) {
      _log.w('update download failed: $failure');
      await _gate.fail<void>(
        failureBuilder: (dialogCtx) => buildUpdateResultDialog(
          dialogCtx,
          _asCheckFailure(failure),
        ),
      );
      return null;
    }
    await _gate.succeed();
    // Closing the window is an animation, and a cancel can land inside it: a
    // press that was already in flight when the transfer finished resolves once
    // the route is pointer-ignored, which is after the check at the top of this
    // method and after the package is complete. Cancel still means cancel, so
    // the run reports nothing and drops what it verified rather than handing
    // back a package no one is going to install. The same gap swallows the
    // caller's interest: a dismissal landing here pops the caller's own route
    // rather than this window, so the cancel flag stays clear and only
    // [stillWanted] can say no.
    if (_cancelled || _abandoned) {
      if (_cancelled) {
        _log.i('update download cancelled while the window was closing');
      } else {
        _log.i('update download dropped while the window was closing: '
            'the caller went away');
      }
      await discardDownload(file);
      return null;
    }
    return file;
  }

  /// Whether the caller can no longer use this run's package.
  bool get _abandoned => !(stillWanted?.call() ?? true);

  Widget _buildProgress(BuildContext dialogCtx) {
    final t = getLocalizations(dialogCtx);
    return PopScope(
      // A dismissal the user made — a platform back gesture, an Esc — routes
      // through [stop] too, so it ends the transfer instead of leaving a body
      // still being pulled off the network behind a closed window. The pop this
      // class performs itself is not a dismissal and is ignored.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_closing) stop();
      },
      child: ValueListenableBuilder<DownloadProgress>(
        valueListenable: _progress,
        builder: (context, value, _) {
          final done = value.total > 0 && value.received >= value.total;
          return AlertDialog(
            title: Text(t.download_and_update),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  done
                      ? t.update_download_verifying
                      : t.update_download_progress(
                          formatFileSize(value.received),
                          formatFileSize(value.total),
                        ),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: value.total > 0 ? value.received / value.total : null,
                ),
                if (notice != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    notice!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                // Through the gate, which owns the route: a second pop from the
                // flow once the transfer unwinds would take the caller's page
                // with it.
                onPressed: () {
                  stop();
                  // The gate owns the route from here, so the pop that follows
                  // is ours — a second pop from the flow once the transfer
                  // unwinds would take the caller's page with it.
                  _closing = true;
                  unawaited(_gate.succeed());
                },
                child: Text(t.cancel),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The report the dialog shows for a transfer that did not land.
///
/// The detail comes along because a status is what picks the sentence: a
/// throttled download, a refused one and a full disk each need different words,
/// and collapsing them is what used to tell a reader with no space to check
/// their connection.
CheckFailed _asCheckFailure(Object? error) => switch (error) {
      UpdateDownloadException(:final reason, :final detail) => CheckFailed(
          switch (reason) {
            DownloadFailure.network => UpdateFailure.network,
            DownloadFailure.http => UpdateFailure.http,
            DownloadFailure.storage => UpdateFailure.notWritable,
            DownloadFailure.interrupted => UpdateFailure.downloadInterrupted,
            DownloadFailure.sizeMismatch => UpdateFailure.sizeMismatch,
            DownloadFailure.hashMismatch => UpdateFailure.hashMismatch,
            // Deliberately reuses the interrupted wording: a cancelled transfer
            // never reaches this switch (the cancel path returns first), so the
            // enum case exists for logs and tests, not for a message.
            DownloadFailure.cancelled => UpdateFailure.downloadInterrupted,
          },
          detail: detail,
        ),
      _ => const CheckFailed(UpdateFailure.network),
    };
