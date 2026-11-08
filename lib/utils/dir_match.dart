import 'dart:convert';

import 'package:iris/utils/path_conv.dart' show canonicalPath;

/// 指定/匹配 × 递归/非递归 — how a rule selects the directories it covers.
///
/// Single source of truth shared by Virtual Media rules and 副音 source rules
/// (extracted from `vm_resolver.dart`); keeping one tested implementation
/// avoids the two matchers drifting apart.
enum DirMatchMode {
  /// 指定目录（非递归）: only files whose DIRECT parent is one of [paths].
  specifiedDir,

  /// 指定目录（递归）: all media beneath the picked directories.
  specifiedDirRecursive,

  /// 匹配目录（非递归）: directories whose base name satisfies every
  /// activated pattern entry; only their direct media match.
  patternDir,

  /// 匹配目录（递归）: matched directories plus their whole subtrees.
  patternDirRecursive,
}

/// One pattern condition of a 匹配目录 rule. Users never write globs — the
/// four kinds cover the everyday cases and regex is the escape hatch.
/// Several entries under one rule are AND-ed (every ACTIVATED entry must hold).
enum DirPatternKind {
  /// 匹配目录名前缀.
  prefix,

  /// 匹配目录名后缀.
  suffix,

  /// 目录包含内容.
  contains,

  /// 按正则表达式.
  regex,
}

/// One pattern condition entry. [pinned] is display-only (pinned entries list
/// first in the editor) and carries no resolution semantics.
class DirPatternEntry {
  const DirPatternEntry({
    required this.kind,
    this.text = '',
    this.activated = true,
    this.pinned = false,
  });

  factory DirPatternEntry.fromJson(Map<String, dynamic> json) {
    final kind = DirPatternKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    return DirPatternEntry(
      kind: kind ?? DirPatternKind.contains,
      text: (json['text'] as String?) ?? '',
      activated: (json['activated'] as bool?) ?? true,
      pinned: (json['pinned'] as bool?) ?? false,
    );
  }

  final DirPatternKind kind;
  final String text;
  final bool activated;
  final bool pinned;

  DirPatternEntry copyWith({
    DirPatternKind? kind,
    String? text,
    bool? activated,
    bool? pinned,
  }) =>
      DirPatternEntry(
        kind: kind ?? this.kind,
        text: text ?? this.text,
        activated: activated ?? this.activated,
        pinned: pinned ?? this.pinned,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'text': text,
        'activated': activated,
        'pinned': pinned,
      };

  @override
  bool operator ==(Object other) =>
      other is DirPatternEntry &&
      other.kind == kind &&
      other.text == text &&
      other.activated == activated &&
      other.pinned == pinned;

  @override
  int get hashCode => Object.hash(kind, text, activated, pinned);
}

/// Whether the media file at [fullPath] (with its [parentPath]) falls under a
/// directory rule.
///
/// [paths] are canonical storage-relative picker paths (a UNION); the file's
/// parent may be absolute in the DB (`E:/vault/...`) while the rule path is
/// relative (`vault/...`), so directory equality compares segment TAILS.
///
/// Hot loops (resolve × files) must use [compileDirRule] once per rule plus
/// [compiledDirRuleMatchesFile] per file instead — this entry compiles on
/// every call.
bool dirRuleMatchesFile({
  required DirMatchMode mode,
  required List<String> paths,
  required List<DirPatternEntry> patterns,
  required String fullPath,
  required String parentPath,
}) =>
    compiledDirRuleMatchesFile(
      compileDirRule(mode: mode, paths: paths, patterns: patterns),
      fullPath: fullPath,
      parentPath: parentPath,
    );

/// One precompiled pattern condition: text trimmed + lowered once, so per-file
/// matching does no allocation beyond the base-name slice.
class CompiledDirPattern {
  const CompiledDirPattern({
    required this.kind,
    required this.text,
    required this.lower,
  });

  final DirPatternKind kind;
  final String text;
  final String lower;
}

/// A directory rule with everything precomputed: canonical paths/roots once,
/// activated patterns filtered + deterministically ordered + lowered once.
/// Compile once per rule, match per file with [compiledDirRuleMatchesFile].
class CompiledDirRule {
  const CompiledDirRule._({
    required this.mode,
    required this.canonicalPaths,
    required this.roots,
    required this.patterns,
  });

  final DirMatchMode mode;
  final List<String> canonicalPaths;
  final Set<String> roots;
  final List<CompiledDirPattern> patterns;
}

/// Compiles a directory rule for repeated matching (same semantics as
/// [dirRuleMatchesFile], no per-file allocation).
CompiledDirRule compileDirRule({
  required DirMatchMode mode,
  required List<String> paths,
  required List<DirPatternEntry> patterns,
}) {
  final canonicalPaths = [for (final p in paths) canonicalPath(p)];
  final activated = patterns.where((p) => p.activated).toList()
    ..sort(_patternDisplayOrder);
  return CompiledDirRule._(
    mode: mode,
    canonicalPaths: canonicalPaths,
    roots: canonicalPaths.toSet(),
    patterns: [
      for (final p in activated)
        CompiledDirPattern(          kind: p.kind,
          text: p.text.trim(),
          lower: p.text.trim().toLowerCase(),
        ),
    ],
  );
}

/// Matches one file against a precompiled rule — same behavior as
/// [dirRuleMatchesFile] without per-file setup cost.
bool compiledDirRuleMatchesFile(
  CompiledDirRule compiled, {
  required String fullPath,
  required String parentPath,
}) {
  switch (compiled.mode) {
    case DirMatchMode.specifiedDir:
      if (compiled.canonicalPaths.isEmpty) return false;
      return compiled.canonicalPaths
          .any((p) => _dirsEqual(p, parentPath));

    case DirMatchMode.specifiedDirRecursive:
      if (compiled.roots.isEmpty) return false;
      return compiled.roots.any((r) => _under(r, fullPath));

    case DirMatchMode.patternDir:
      return _compiledMatches(compiled.patterns, dirBaseNameOf(parentPath));

    case DirMatchMode.patternDirRecursive:
      if (_compiledMatches(
          compiled.patterns, dirBaseNameOf(parentPath))) {
        return true;
      }
      // Under a matched ancestor: walk the file's ancestor directories and
      // let ANY matching base name qualify the whole subtree.
      var ancestor = parentPath;
      while (ancestor.isNotEmpty) {
        if (_compiledMatches(
            compiled.patterns, dirBaseNameOf(ancestor))) {
          return true;
        }
        final idx = ancestor.lastIndexOf('/');
        ancestor = idx < 0 ? '' : ancestor.substring(0, idx);
      }
      return false;
  }
}

/// AND over the precompiled entries. Zero entries never match; an empty-text
/// entry fails the whole AND (same fail-closed shape as [dirMatchesPatterns]).
bool _compiledMatches(
    List<CompiledDirPattern> patterns, String baseName) {
  if (patterns.isEmpty) return false;
  final lower = baseName.toLowerCase();
  for (final p in patterns) {
    if (p.text.isEmpty) return false;
    final ok = switch (p.kind) {
      DirPatternKind.prefix => lower.startsWith(p.lower),
      DirPatternKind.suffix => lower.endsWith(p.lower),
      DirPatternKind.contains => lower.contains(p.lower),
      DirPatternKind.regex => _regexMatches(p.text, baseName),
    };
    if (!ok) return false;
  }
  return true;
}

/// Last path segment of a directory path.
String dirBaseNameOf(String dirPath) {
  final idx = dirPath.lastIndexOf('/');
  return idx < 0 ? dirPath : dirPath.substring(idx + 1);
}

/// Matches a directory base name against EVERY activated pattern entry
/// (AND semantics). Zero activated entries never match anything — the user
/// decides what matches by activating conditions.
bool dirMatchesPatterns(List<DirPatternEntry> patterns, String baseName) {
  final activated = patterns.where((p) => p.activated).toList()
    ..sort(_patternDisplayOrder);
  if (activated.isEmpty) return false;
  final lower = baseName.toLowerCase();
  for (final p in activated) {
    final text = p.text.trim();
    if (text.isEmpty) return false;
    final ok = switch (p.kind) {
      DirPatternKind.prefix => lower.startsWith(text.toLowerCase()),
      DirPatternKind.suffix => lower.endsWith(text.toLowerCase()),
      DirPatternKind.contains => lower.contains(text.toLowerCase()),
      DirPatternKind.regex => _regexMatches(text, baseName),
    };
    if (!ok) return false;
  }
  return true;
}

/// Decodes a patterns JSON column defensively; malformed payloads degrade to
/// an empty list, never throw.
List<DirPatternEntry> decodeDirPatterns(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    final out = <DirPatternEntry>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      out.add(DirPatternEntry.fromJson(Map<String, dynamic>.from(entry)));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// Whether media path [fullPath] falls under directory [root].
///
/// The DB stores ABSOLUTE windows paths (`E:/vault/003/sub/c.mp4`) while
/// rules store STORAGE-RELATIVE picker paths (`vault/003`). Both are
/// canonical segment sequences; the file's parent directory (fullPath minus
/// its last name segment) must CONTAIN the rule's directory segments as a
/// contiguous run.
bool _under(String root, String fullPath) {
  if (root.isEmpty) return true;
  final rootSegs = root.split('/').where((e) => e.isNotEmpty).toList();
  final allSegs = fullPath.split('/').where((e) => e.isNotEmpty).toList();
  if (allSegs.isEmpty) return false;
  final dirSegs = allSegs.sublist(0, allSegs.length - 1);
  if (dirSegs.length < rootSegs.length) return false;
  for (var i = 0; i + rootSegs.length <= dirSegs.length; i++) {
    if (dirSegs.sublist(i, i + rootSegs.length).join('/') ==
        rootSegs.join('/')) {
      return true;
    }
  }
  return false;
}

/// Directory-equality tolerant of the absolute-vs-relative shape mismatch:
/// equal when the shorter segment sequence equals the LONGER's TAIL (the
/// direct-parent match — subdirectories are intentionally excluded for
/// `specifiedDir`).
bool _dirsEqual(String a, String b) {
  if (a.isEmpty || b.isEmpty) return a == b;
  final aSegs = a.split('/').where((e) => e.isNotEmpty).toList();
  final bSegs = b.split('/').where((e) => e.isNotEmpty).toList();
  final short = aSegs.length <= bSegs.length ? aSegs : bSegs;
  final long = aSegs.length <= bSegs.length ? bSegs : aSegs;
  if (long.length < short.length) return false;
  return long.sublist(long.length - short.length).join('/') == short.join('/');
}

/// Pinned entries display first; matching is order-blind, but a deterministic
/// iteration order keeps behavior reproducible.
int _patternDisplayOrder(DirPatternEntry a, DirPatternEntry b) {
  if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
  return a.text.compareTo(b.text);
}

final _regexCache = <String, RegExp?>{};

/// Invalid regexes fail CLOSED (condition not satisfied) instead of throwing
/// into the resolve pipeline.
bool _regexMatches(String pattern, String value) {
  if (!_regexCache.containsKey(pattern)) {
    RegExp? re;
    try {
      re = RegExp(pattern, caseSensitive: false);
    } catch (_) {
      re = null;
    }
    _regexCache[pattern] = re;
  }
  return _regexCache[pattern]?.hasMatch(value) ?? false;
}
