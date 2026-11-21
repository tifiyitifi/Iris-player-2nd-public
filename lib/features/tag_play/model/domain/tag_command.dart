/// Numeric command grammar of the tag-play input bar.
///
/// One line drives every surface: the Windows numpad entry keys prefill the
/// operator, the sheet's input bar accepts the same text by hand, and the
/// parser is the single authority for what a command means — no I/O here, so
/// the grammar is unit-testable in isolation.
///
/// The grammar is deliberately LENIENT: stray characters are ignored rather
/// than rejected, so a pasted ` 02.01.3 ` reads the same as `2.1.3`. Only a
/// genuinely unusable line (no operator, or no usable number) is an error.
library;

/// The three command operators, in the order they are documented.
const String kTagCommandOperators = '+-*';

/// The no-tag play target: `*0` plays the original (untagged) list, the same
/// destination as the sheet's "no tag" row. Only `*` accepts it as a play
/// target.
const int kTagCommandNoTagOrdinal = 0;

/// The "all tags" target of `+`/`-`: `+0` adds the current file to every tag
/// and `-0` removes it from every tag. It only applies when `0` stands alone;
/// in a mixed line such as `+0.2` the `0` is ignored and only `2` is used.
const int kTagCommandAllTagsOrdinal = 0;

/// What the command does with the tagged ordinals.
enum TagCommandKind {
  /// `+` — add the current file to the addressed tags.
  add,

  /// `-` — remove the current file from the addressed tags.
  remove,

  /// `*` — switch playback into the addressed tag's view.
  play,
}

/// Validated command: a kind plus 1-based ordinals in the sheet's display
/// order (pins first — see `tagPlayDisplayOrder`). Duplicates collapse to
/// first-seen order so `+1.1` is the same command as `+1`.
class TagCommand {
  const TagCommand({
    required this.kind,
    required this.ordinals,
    this.allTags = false,
  });

  final TagCommandKind kind;
  final List<int> ordinals;

  /// `+0` / `-0`: apply to every tag instead of [ordinals]. A lone `0` sets
  /// this; a mixed line such as `+0.2` drops the `0` and leaves [ordinals].
  final bool allTags;
}

/// Why a command line could not be understood. Rendered as inline red text
/// under the input bar — never a dialog.
enum TagCommandError {
  /// Nothing but ignored characters.
  empty,

  /// First meaningful character is not one of `+`, `-`, `*`.
  missingOperator,

  /// Operator given but no usable 1-based number follows.
  noOrdinals,

  /// `*` addresses exactly one tag; several were given.
  playNeedsSingle,
}

sealed class TagCommandParseResult {
  const TagCommandParseResult();
}

class TagCommandParsed extends TagCommandParseResult {
  const TagCommandParsed(this.command);

  final TagCommand command;
}

class TagCommandInvalid extends TagCommandParseResult {
  const TagCommandInvalid(this.error);

  final TagCommandError error;
}

/// Operator character that introduces [kind] — used to prefill the input bar
/// when a numpad entry key opens the sheet.
String tagCommandOperator(TagCommandKind kind) => switch (kind) {
      TagCommandKind.add => '+',
      TagCommandKind.remove => '-',
      TagCommandKind.play => '*',
    };

/// Characters the grammar cannot use; dropped before parsing. Shared so the
/// input bar can reproduce the same normalization when it rewrites the field.
final RegExp kTagCommandIgnoredChars = RegExp(r'[^0-9.*+\-]');

/// Any separator: a dot, or a stray operator sign left after the first one.
final RegExp _separator = RegExp(r'[.+\-*]');

/// Collapses a hand-typed edit: an operator is the command MODE, not a plain
/// character, so typing `+`, `-` or `*` after existing text restarts the line
/// as that single operator (`+1.2` then `*` → `*`).
///
/// Returns the replacement text, or null when the edit stands as-is. Only a
/// lone operator inserted AFTER the first column resets — prefixing the
/// missing operator (`1.2` → `+1.2`) or pasting a whole command is untouched.
String? tagOperatorResetOnEdit(String oldText, String newText) {
  if (oldText == newText) return null;
  final minLength =
      oldText.length < newText.length ? oldText.length : newText.length;
  var prefix = 0;
  while (prefix < minLength && oldText[prefix] == newText[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < minLength - prefix &&
      oldText[oldText.length - 1 - suffix] ==
          newText[newText.length - 1 - suffix]) {
    suffix++;
  }
  final inserted = newText.substring(prefix, newText.length - suffix);
  if (prefix > 0 &&
      inserted.length == 1 &&
      kTagCommandOperators.contains(inserted)) {
    return inserted;
  }
  return null;
}

/// Parses one command line, e.g. `+1.2.5`, `-2.4`, `*3`, `*0`.
TagCommandParseResult parseTagCommand(String raw) {
  // Illegal characters (whitespace, letters, punctuation, ...) are dropped
  // outright — never rejected.
  final cleaned = raw.replaceAll(kTagCommandIgnoredChars, '');
  if (cleaned.isEmpty) return const TagCommandInvalid(TagCommandError.empty);

  final TagCommandKind kind;
  switch (cleaned[0]) {
    case '+':
      kind = TagCommandKind.add;
    case '-':
      kind = TagCommandKind.remove;
    case '*':
      kind = TagCommandKind.play;
    default:
      return const TagCommandInvalid(TagCommandError.missingOperator);
  }

  // `int.parse` folds leading zeros (`02` → 2). Blank segments name no tag
  // and are skipped instead of failing the line. `0` is the no-tag target for
  // `*`, and for `+`/`-` it means "all tags" when it stands alone (a mixed
  // line drops it).
  final values = <int>[];
  for (final segment in cleaned.substring(1).split(_separator)) {
    final value = int.tryParse(segment);
    if (value == null) continue;
    if (!values.contains(value)) values.add(value);
  }

  if (kind == TagCommandKind.play) {
    if (values.isEmpty) {
      return const TagCommandInvalid(TagCommandError.noOrdinals);
    }
    if (values.length != 1) {
      return const TagCommandInvalid(TagCommandError.playNeedsSingle);
    }
    return TagCommandParsed(TagCommand(kind: kind, ordinals: values));
  }

  // add / remove: a lone 0 addresses every tag; any other line drops the 0.
  final allTags =
      values.length == 1 && values.first == kTagCommandAllTagsOrdinal;
  final ordinals = values.where((v) => v > 0).toList(growable: false);
  if (ordinals.isEmpty && !allTags) {
    return const TagCommandInvalid(TagCommandError.noOrdinals);
  }

  return TagCommandParsed(
    TagCommand(kind: kind, ordinals: ordinals, allTags: allTags),
  );
}
