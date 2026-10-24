import 'dart:convert';

import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/models/file.dart';

/// A file the new window must play, in the SENDER's own terms.
///
/// The receiving window only needs [FileItem]'s identity fields (the scenario
/// layer maps an explicit item back to `storageId + storage-relative path`), but
/// carrying name/uri/type too keeps the payload self-contained: no DB lookup or
/// storage round-trip is needed before the play action can run.
class NewWindowFile {
  const NewWindowFile({
    required this.storageId,
    required this.name,
    required this.uri,
    required this.path,
    this.type = ContentType.video,
  });

  final String storageId;
  final String name;
  final String uri;

  /// Storage-relative path segments (schema v38 convention).
  final List<String> path;
  final ContentType type;

  FileItem toFileItem() => FileItem(
        storageId: storageId,
        name: name,
        uri: uri,
        path: path,
        type: type,
      );

  Map<String, dynamic> toJson() => {
        's': storageId,
        'n': name,
        'u': uri,
        'p': path,
        't': type.name,
      };

  factory NewWindowFile.fromJson(Map<String, dynamic> json) => NewWindowFile(
        storageId: json['s'] as String? ?? '',
        name: json['n'] as String? ?? '',
        uri: json['u'] as String? ?? '',
        path: (json['p'] as List?)?.map((e) => '$e').toList() ?? const [],
        type: _contentTypeFromName(json['t']),
      );
}

ContentType _contentTypeFromName(Object? name) {
  for (final v in ContentType.values) {
    if (v.name == name) return v;
  }
  return ContentType.video;
}

/// A directory SOURCE the new window must play (scenario "directory source":
/// the queue is resolved from `media_nodes`, not from a flat file list).
class NewWindowFolder {
  const NewWindowFolder({
    required this.storageId,
    required this.path,
    this.recursive = true,
  });

  final String storageId;

  /// Canonical storage-relative folder path ('' = the storage root).
  final String path;
  final bool recursive;

  Map<String, dynamic> toJson() => {
        's': storageId,
        'p': path,
        'r': recursive,
      };

  factory NewWindowFolder.fromJson(Map<String, dynamic> json) => NewWindowFolder(
        storageId: json['s'] as String? ?? '',
        path: json['p'] as String? ?? '',
        recursive: json['r'] as bool? ?? true,
      );
}

/// What a freshly spawned IRIS window must do once its database and stores are
/// ready.
///
/// WHY: every "play in a new window" entry translates the user's intent into one
/// of these, and the new process replays it through the SAME scenario actions the
/// source window would have run (folder scope / selection override / scenario
/// resume). That keeps two windows behaving identically for the same gesture and
/// avoids a second play-interpretation layer.
///
/// Transport: a single `--open-request=<base64url(json)>` argument. One opaque
/// token survives Windows command-line quoting untouched (paths with spaces,
/// quotes or CJK), and the receiving side can reject a corrupt payload instead of
/// half-launching.
class NewWindowRequest {
  const NewWindowRequest({
    this.folders = const [],
    this.files = const [],
    this.startFile,
    this.startFolderPath,
    this.startItemPath,
    this.sortField = ScenarioSortField.name,
    this.sortDirection = SortDirection.asc,
    this.scenarioId,
    this.libraryId,
    this.openStorageId,
    this.openPath,
  });

  /// CLI flag; the payload is appended after `=`.
  static const String flag = '--open-request';

  /// Directory sources, played before [files] (same order contract as the
  /// scenario selection override).
  final List<NewWindowFolder> folders;

  /// Explicit file items, played after [folders].
  final List<NewWindowFile> files;

  /// When set, the window plays [startFolderPath] as a non-recursive folder
  /// scope and lands on this file (equivalent to tapping it in the browser).
  final NewWindowFile? startFile;
  final String? startFolderPath;
  final String? startItemPath;

  final ScenarioSortField sortField;
  final SortDirection sortDirection;

  /// Activate this saved scenario and resume it (scenario tile entry).
  final String? scenarioId;

  /// Open this media library in the browser, WITHOUT playing (library tile).
  final String? libraryId;

  /// Open this storage-relative folder in the browser, WITHOUT playing
  /// (favorites entry). [openPath] is the stored path SEGMENTS list (a favorite
  /// may carry a leading empty segment, and the browser store expects the exact
  /// same list the in-place tap hands it).
  final String? openStorageId;
  final List<String>? openPath;

  bool get isPlaybackRequest =>
      scenarioId == null && libraryId == null && openStorageId == null;

  String encode() =>
      base64Url.encode(utf8.encode(jsonEncode(toJson())));

  static NewWindowRequest? decode(String raw) {
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(raw)));
      if (json is! Map<String, dynamic>) return null;
      return NewWindowRequest.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Parses the launcher argument out of [args]; null when this is a normal
  /// launch (or the payload is corrupt).
  static NewWindowRequest? parse(List<String> args) {
    for (final arg in args) {
      if (!arg.startsWith('$flag=')) continue;
      return decode(arg.substring(flag.length + 1));
    }
    return null;
  }

  List<String> toArguments() => ['$flag=${encode()}'];

  /// Human-readable form for startup logs (never includes secrets).
  String describe() => 'new-window[scenario=${scenarioId ?? '-'} '
      'library=${libraryId ?? '-'} open=${openStorageId ?? '-'} '
      'folders=${{for (final f in folders) '${f.storageId}:${f.path}${f.recursive ? '/*' : ''}'}} '
      'files=${files.length} start=${startItemPath ?? '-'}]';

  Map<String, dynamic> toJson() => {
        if (folders.isNotEmpty)
          'folders': [for (final f in folders) f.toJson()],
        if (files.isNotEmpty) 'files': [for (final f in files) f.toJson()],
        if (startFile != null)
          'start': {
            'f': startFile!.toJson(),
            if (startFolderPath != null) 'fp': startFolderPath,
            if (startItemPath != null) 'ip': startItemPath,
          },
        'sort': [sortField.name, sortDirection.name],
        if (scenarioId != null) 'scenario': scenarioId,
        if (libraryId != null) 'library': libraryId,
        if (openStorageId != null) ...{
          'open': {'s': openStorageId, 'p': openPath ?? const <String>[]},
        },
      };

  factory NewWindowRequest.fromJson(Map<String, dynamic> json) {
    final start = json['start'];
    final startMap = start is Map<String, dynamic> ? start : null;
    final open = json['open'];
    final openMap = open is Map<String, dynamic> ? open : null;
    final sort = json['sort'];
    final sortList = sort is List ? sort : const [];

    ScenarioSortField field = ScenarioSortField.name;
    SortDirection direction = SortDirection.asc;
    if (sortList.length == 2) {
      field = _sortFieldFromName(sortList[0]);
      direction = sortList[1] == SortDirection.desc.name
          ? SortDirection.desc
          : SortDirection.asc;
    }

    final startFileJson = startMap?['f'];
    return NewWindowRequest(
      folders: [
        for (final f in (json['folders'] as List? ?? const []))
          if (f is Map<String, dynamic>) NewWindowFolder.fromJson(f),
      ],
      files: [
        for (final f in (json['files'] as List? ?? const []))
          if (f is Map<String, dynamic>) NewWindowFile.fromJson(f),
      ],
      startFile: startFileJson is Map<String, dynamic>
          ? NewWindowFile.fromJson(startFileJson)
          : null,
      startFolderPath: startMap?['fp'] as String?,
      startItemPath: startMap?['ip'] as String?,
      sortField: field,
      sortDirection: direction,
      scenarioId: json['scenario'] as String?,
      libraryId: json['library'] as String?,
      openStorageId: openMap?['s'] as String?,
      openPath: (openMap?['p'] as List?)?.map((e) => '$e').toList(),
    );
  }

  static ScenarioSortField _sortFieldFromName(Object? name) {
    for (final v in ScenarioSortField.values) {
      if (v.name == name) return v;
    }
    return ScenarioSortField.name;
  }
}
