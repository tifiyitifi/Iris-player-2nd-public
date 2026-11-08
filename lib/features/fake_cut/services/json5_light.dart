/// Tolerant reader for the JSON5 subset used by LosslessCut `.llc` projects.
///
/// WHY not `dart:convert`: a `.llc` file is JSON5 — unquoted keys, single
/// quotes, trailing commas, `//` / `/* */` comments and `+`-signed numbers all
/// appear in the wild (see `lossless-cut/src/renderer/src/edlStore.ts`, which
/// reads the file with the `json5` npm package). IRIS has no JSON5 dependency,
/// and adding one for a 2 KB project file is not worth the supply-chain cost.
///
/// The parser implements exactly the JSON5 value grammar a project needs and
/// REJECTS everything else with [Json5FormatException] + an offset, so a
/// corrupt project fails loudly instead of producing a half-parsed plan.
///
/// Deliberately unsupported: non-finite numbers (`Infinity` / `NaN`) and
/// escaped-identifier keys (`\u0061`). No LosslessCut project contains them,
/// and accepting them would only mask corruption.
library;

/// A JSON5 syntax error carrying the absolute character offset it was found at.
class Json5FormatException implements Exception {
  const Json5FormatException(this.message, this.offset);

  final String message;

  /// Zero-based offset into the parsed source.
  final int offset;

  @override
  String toString() => 'Json5FormatException: $message (offset $offset)';
}

/// Parses [source] as JSON5 and returns plain Dart values:
/// `Map<String, Object?>`, `List<Object?>`, `String`, `num`, `bool` or `null`.
Object? parseJson5(String source) => _Json5Parser(source).parseDocument();

class _Json5Parser {
  _Json5Parser(this.src);

  final String src;
  int _pos = 0;

  /// Maximum container nesting the reader accepts.
  ///
  /// A `.llc` is three levels deep (`{ cutSegments: [ { … } ] }`); anything
  /// deeper is corruption. Unbounded recursion turned a project-sized file of
  /// `[` into a `StackOverflowError` — an Error, so the `on FormatException`
  /// handling upstream could not stop it and one broken project emptied the
  /// whole directory's list.
  static const int maxDepth = 32;

  int _depth = 0;

  Object? parseDocument() {
    _skipTrivia();
    final Object? value = _parseValue();
    _skipTrivia();
    if (_pos < src.length) _fail('unexpected trailing content');
    return value;
  }

  Object? _parseValue() {
    if (_pos >= src.length) _fail('unexpected end of input');
    final String ch = src[_pos];
    switch (ch) {
      case '{':
        return _nested(_parseObject);
      case '[':
        return _nested(_parseArray);
      case '"':
      case "'":
        return _parseString();
    }
    return _parseBareToken();
  }

  Object? _nested(Object? Function() parse) {
    if (_depth >= maxDepth) {
      _fail('nested more than $maxDepth levels');
    }
    _depth++;
    try {
      return parse();
    } finally {
      _depth--;
    }
  }

  Map<String, Object?> _parseObject() {
    _expect('{');
    final Map<String, Object?> out = <String, Object?>{};
    while (true) {
      _skipTrivia();
      if (_eat('}')) return out;
      final String key = _parseKey();
      _skipTrivia();
      _expect(':');
      _skipTrivia();
      out[key] = _parseValue();
      _skipTrivia();
      if (_eat(',')) continue;
      _skipTrivia();
      if (_eat('}')) return out;
      _fail("expected ',' or '}' in object");
    }
  }

  List<Object?> _parseArray() {
    _expect('[');
    final List<Object?> out = <Object?>[];
    while (true) {
      _skipTrivia();
      if (_eat(']')) return out;
      out.add(_parseValue());
      _skipTrivia();
      if (_eat(',')) continue;
      _skipTrivia();
      if (_eat(']')) return out;
      _fail("expected ',' or ']' in array");
    }
  }

  String _parseKey() {
    if (_pos >= src.length) _fail('unexpected end of input in object key');
    final String ch = src[_pos];
    if (ch == '"' || ch == "'") return _parseString();
    final int start = _pos;
    while (_pos < src.length && _isIdentifierChar(src.codeUnitAt(_pos))) {
      _pos++;
    }
    if (_pos == start) _fail('expected an object key');
    return src.substring(start, _pos);
  }

  String _parseString() {
    final String quote = src[_pos];
    _pos++;
    final StringBuffer out = StringBuffer();
    while (true) {
      if (_pos >= src.length) _fail('unterminated string');
      final String ch = src[_pos];
      if (ch == quote) {
        _pos++;
        return out.toString();
      }
      if (ch != r'\') {
        out.write(ch);
        _pos++;
        continue;
      }
      // Escape sequence.
      _pos++;
      if (_pos >= src.length) _fail('unterminated string escape');
      final String esc = src[_pos];
      _pos++;
      switch (esc) {
        case 'b':
          out.write('\b');
        case 'f':
          out.write('\f');
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        case 'v':
          out.write('\v');
        case '0':
          out.write('\u0000');
        case '"':
        case "'":
        case r'\':
        case '/':
          out.write(esc);
        case 'u':
          out.writeCharCode(_readHex(4));
        case 'x':
          out.writeCharCode(_readHex(2));
        case '\r':
          // Line continuation: a backslash immediately before a line break.
          if (_pos < src.length && src[_pos] == '\n') _pos++;
        case '\n':
          break;
        default:
          // Unknown escape: JSON5 keeps the character verbatim.
          out.write(esc);
      }
    }
  }

  int _readHex(int digits) {
    if (_pos + digits > src.length) _fail('truncated escape sequence');
    final String text = src.substring(_pos, _pos + digits);
    final int? value = int.tryParse(text, radix: 16);
    if (value == null) _fail('invalid hex escape "$text"');
    _pos += digits;
    return value;
  }

  /// Parses `true` / `false` / `null` / a number, without surrounding spaces.
  Object? _parseBareToken() {
    final int start = _pos;
    while (_pos < src.length) {
      final String ch = src[_pos];
      if (_isTokenTerminator(ch)) break;
      _pos++;
    }
    if (_pos == start) _fail('expected a value');
    final String token = src.substring(start, _pos);
    switch (token) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null':
        return null;
    }
    final num? number = _parseNumber(token);
    if (number == null) _fail('unsupported value "$token"');
    return number;
  }

  static num? _parseNumber(String token) {
    final String text = token.trim();
    if (text.isEmpty) return null;
    // JSON5 allows a leading `+`; `int.parse` / `double.parse` do too, but be
    // explicit so `+0x10` goes through the hex path below.
    final bool negative = text.startsWith('-');
    final String body = (text.startsWith('+') || negative)
        ? text.substring(1)
        : text;
    if (body.isEmpty) return null;
    if (body.length > 2 && (body.startsWith('0x') || body.startsWith('0X'))) {
      final int? hex = int.tryParse(body.substring(2), radix: 16);
      if (hex == null) return null;
      return negative ? -hex : hex;
    }
    // Reject `Infinity` / `NaN` and any other identifier-shaped token: a plan
    // coordinate must be a real number. `double.tryParse` happily accepts the
    // strings "Infinity" / "NaN", hence the finiteness check.
    final int? asInt = int.tryParse(text);
    if (asInt != null) return asInt;
    final double? asDouble = double.tryParse(text);
    if (asDouble == null || !asDouble.isFinite) return null;
    return asDouble;
  }

  static bool _isIdentifierChar(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return true; // 0-9
    if (codeUnit >= 0x41 && codeUnit <= 0x5A) return true; // A-Z
    if (codeUnit >= 0x61 && codeUnit <= 0x7A) return true; // a-z
    return codeUnit == 0x24 || codeUnit == 0x5F; // $ _
  }

  static bool _isTokenTerminator(String ch) {
    switch (ch) {
      case ',':
      case ']':
      case '}':
      case ':':
      case ' ':
      case '\t':
      case '\r':
      case '\n':
      case '/':
        return true;
    }
    return false;
  }

  void _skipTrivia() {
    while (_pos < src.length) {
      final String ch = src[_pos];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        _pos++;
        continue;
      }
      if (ch == '\uFEFF') {
        _pos++;
        continue;
      }
      if (ch == '/' && _pos + 1 < src.length) {
        final String next = src[_pos + 1];
        if (next == '/') {
          _pos += 2;
          while (_pos < src.length && src[_pos] != '\n') {
            _pos++;
          }
          continue;
        }
        if (next == '*') {
          _pos += 2;
          while (_pos + 1 < src.length &&
              !(src[_pos] == '*' && src[_pos + 1] == '/')) {
            _pos++;
          }
          if (_pos + 1 >= src.length) _fail('unterminated block comment');
          _pos += 2;
          continue;
        }
      }
      return;
    }
  }

  bool _eat(String ch) {
    if (_pos < src.length && src[_pos] == ch) {
      _pos++;
      return true;
    }
    return false;
  }

  void _expect(String ch) {
    if (!_eat(ch)) _fail("expected '$ch'");
  }

  Never _fail(String message) => throw Json5FormatException(message, _pos);
}
