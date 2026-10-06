/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Parsing for the BEAM explorer's TABLE format.
///
/// The explorer answers most list endpoints with
///
/// ```json
/// {"type": "table",
///  "value": [[<header cells>], <row>, <row>, ...],
///  "more": {"hMax": 4067909}}
/// ```
///
/// What the live explorer actually sends (checked against
/// `/contract?id=<DEX>&state=1` and `/asset?id=174` on 2026-10-06):
///
/// * Row 0 is a header row only when every cell is `{"type": "th", ...}`.
///   The nested `Funds` tables inside `Calls history` have **no** header row:
///   their first row is data. Treating row 0 as headers unconditionally (as
///   LightWallet's `parseExplorerTableRows` does) silently drops a fund entry.
/// * A cell is typed, `{"type": "aid" | "cid" | "blob" | "amount" | "height" |
///   "time" | ..., "value": ...}`, or a raw number or string. `""` means
///   "no value".
/// * A cell can be a table (`Funds`) or a plain map of typed cells
///   (`Arguments`: `{"Buy": {"type": "aid", "value": 47}, ...}`).
/// * A row can be a group, `{"type": "group", "value": [<row>, <row>, ...]}`.
///   In `Calls history` the first row is the call and the rest are the calls
///   it made into other contracts (their `Height` cell is `""`).
/// * Amounts are integers in some tables (`Locked Funds`) and signed strings
///   in others (`"+7876534611"`, `"-77978275"` in `Funds`). Rates are strings
///   such as `"9.1558504 E-2"`. Use the `parseExplorer*` helpers, not casts.
library;

import 'dart:math' as math;

/// A decoded explorer table.
class ExplorerTable {
  ExplorerTable._(this.headers, this.rows, this.more);

  /// Column names from the header row, or empty when the table has none.
  final List<String> headers;

  /// Every row in order, with groups flattened. See [ExplorerTableRow.depth].
  final List<ExplorerTableRow> rows;

  /// The pagination object, e.g. `{"hMax": 4067909}`, or null.
  final Map<String, Object?>? more;

  /// The `hMax` paging cursor from [more], if any.
  int? get moreHMax => more == null ? null : parseExplorerInt(more!['hMax']);

  /// Top-level rows: ungrouped rows and the first row of each group.
  Iterable<ExplorerTableRow> get leadRows => rows.where((r) => r.depth == 0);

  /// All rows of group [groupId], lead row first.
  List<ExplorerTableRow> group(int groupId) =>
      rows.where((r) => r.groupId == groupId).toList(growable: false);

  /// Each row as `header -> value`, with typed cells unwrapped (nested
  /// tables become [ExplorerTable]). Only meaningful when [headers] is set.
  List<Map<String, Object?>> toMaps() =>
      rows.map((r) => r.toMap()).toList(growable: false);

  /// Whether [json] has the shape of a table.
  static bool isTable(Object? json) =>
      json is Map<String, Object?> &&
      json['type'] == 'table' &&
      json['value'] is List<Object?>;

  /// Like [parse], but returns null instead of throwing.
  static ExplorerTable? tryParse(Object? json) {
    try {
      return parse(json);
    } on FormatException {
      return null;
    }
  }

  /// Decodes a `{"type": "table", "value": [...]}` object.
  ///
  /// Throws [FormatException] when [json] is not a table.
  static ExplorerTable parse(Object? json) {
    if (!isTable(json)) {
      throw const FormatException('not an explorer table');
    }
    final map = json as Map<String, Object?>;
    final value = map['value'] as List<Object?>;
    final moreRaw = map['more'];
    final more = moreRaw is Map<String, Object?>
        ? Map<String, Object?>.unmodifiable(moreRaw)
        : null;

    var headers = const <String>[];
    var start = 0;
    if (value.isNotEmpty && _isHeaderRow(value.first)) {
      headers = List<String>.unmodifiable(
        (value.first as List<Object?>).map((c) => '${unwrapCell(c) ?? ''}'),
      );
      start = 1;
    }
    final index = <String, int>{};
    for (var i = 0; i < headers.length; i++) {
      index.putIfAbsent(headers[i], () => i);
    }

    final rows = <ExplorerTableRow>[];
    var nextGroup = 0;

    void addGroup(List<Object?> entries, int groupId, int depth) {
      var first = true;
      for (final entry in entries) {
        final entryDepth = first ? depth : depth + 1;
        if (entry is List<Object?>) {
          rows.add(
            ExplorerTableRow._(headers, index, entry, groupId, entryDepth),
          );
          first = false;
        } else if (_isGroup(entry)) {
          final inner = (entry as Map<String, Object?>)['value'];
          addGroup(inner as List<Object?>, groupId, entryDepth);
          first = false;
        }
      }
    }

    for (var i = start; i < value.length; i++) {
      final entry = value[i];
      if (entry is List<Object?>) {
        rows.add(ExplorerTableRow._(headers, index, entry, null, 0));
      } else if (_isGroup(entry)) {
        final inner = (entry as Map<String, Object?>)['value'];
        addGroup(inner as List<Object?>, nextGroup++, 0);
      }
      // Anything else is an entry type this parser does not know; skip it
      // rather than misread it as data.
    }

    return ExplorerTable._(
      headers,
      List<ExplorerTableRow>.unmodifiable(rows),
      more,
    );
  }

  static bool _isHeaderRow(Object? row) =>
      row is List<Object?> &&
      row.isNotEmpty &&
      row.every((c) => c is Map<String, Object?> && c['type'] == 'th');

  static bool _isGroup(Object? entry) =>
      entry is Map<String, Object?> &&
      entry['type'] == 'group' &&
      entry['value'] is List<Object?>;
}

/// One row of an [ExplorerTable].
class ExplorerTableRow {
  ExplorerTableRow._(
    this.headers,
    this._index,
    List<Object?> cells,
    this.groupId,
    this.depth,
  ) : cells = List<Object?>.unmodifiable(cells);

  /// The table's headers (shared by every row).
  final List<String> headers;
  final Map<String, int> _index;

  /// The raw cells, typed wrappers included.
  final List<Object?> cells;

  /// Which group this row belongs to (0, 1, ... in table order), or null
  /// for an ungrouped row.
  final int? groupId;

  /// 0 for a top-level row or the first row of a group; 1 or more for the
  /// rows a group nests under its first row (sub-calls in `Calls history`).
  final int depth;

  bool get isNested => depth > 0;

  /// The raw cell at column [i], or null past the end of the row.
  Object? rawAt(int i) => i >= 0 && i < cells.length ? cells[i] : null;

  /// The raw cell under [header], or null when there is no such column.
  Object? raw(String header) {
    final i = _index[header];
    return i == null ? null : rawAt(i);
  }

  /// The unwrapped value at column [i].
  Object? at(int i) => unwrapCell(rawAt(i));

  /// The unwrapped value under [header].
  Object? operator [](String header) => unwrapCell(raw(header));

  /// The cell's `type` (`aid`, `cid`, `amount`, ...) under [header], or
  /// null for a raw cell.
  String? typeOf(String header) {
    final cell = raw(header);
    if (cell is Map<String, Object?>) {
      final type = cell['type'];
      return type is String ? type : null;
    }
    return null;
  }

  int? intOf(String header) => parseExplorerInt(raw(header));
  BigInt? bigIntOf(String header) => parseExplorerBigInt(raw(header));
  double? doubleOf(String header) => parseExplorerDecimal(raw(header));

  /// The value as text, or null when it is missing or `""`.
  String? stringOf(String header) {
    final v = this[header];
    if (v == null) return null;
    final s = v is String ? v : '$v';
    return s.isEmpty ? null : s;
  }

  /// A nested table under [header] (e.g. `Funds`), or null.
  ExplorerTable? tableOf(String header) => ExplorerTable.tryParse(raw(header));

  /// A plain map under [header] (e.g. `Arguments`) with its typed cells
  /// unwrapped, or null when the cell is not a plain map.
  Map<String, Object?>? mapOf(String header) {
    final cell = raw(header);
    if (cell is! Map<String, Object?> || isTypedCell(cell)) return null;
    return unwrapDeep(cell) as Map<String, Object?>;
  }

  /// `header -> unwrapped value`. Columns beyond [headers] are left out.
  Map<String, Object?> toMap() => {
    for (var i = 0; i < math.min(headers.length, cells.length); i++)
      headers[i]: unwrapDeep(cells[i]),
  };

  @override
  String toString() =>
      'ExplorerTableRow(group: $groupId, depth: $depth, '
      'cells: $cells)';
}

/// Whether [cell] is a `{"type": ..., "value": ...}` wrapper.
bool isTypedCell(Object? cell) =>
    cell is Map<String, Object?> &&
    cell['type'] is String &&
    cell.containsKey('value');

/// The `value` of a typed scalar cell, or [cell] itself for raw cells,
/// plain maps, tables and groups.
Object? unwrapCell(Object? cell) {
  if (!isTypedCell(cell)) return cell;
  final map = cell as Map<String, Object?>;
  final type = map['type'];
  if (type == 'table' || type == 'group') return cell;
  return map['value'];
}

/// Unwraps typed cells all the way down: plain maps and lists are copied
/// with their cells unwrapped, and nested tables become [ExplorerTable].
Object? unwrapDeep(Object? value) {
  if (ExplorerTable.isTable(value)) return ExplorerTable.tryParse(value);
  if (isTypedCell(value)) return unwrapDeep(unwrapCell(value));
  if (value is Map<String, Object?>) {
    return {for (final e in value.entries) e.key: unwrapDeep(e.value)};
  }
  if (value is List<Object?>) return value.map(unwrapDeep).toList();
  return value;
}

/// An integer from a typed or raw cell: `5`, `5.0`, `"5"`, `"+5"`, `"-5"`.
///
/// Returns null for `""`, non-integers, and values outside 64 bits (use
/// [parseExplorerBigInt] for those).
int? parseExplorerInt(Object? cell) {
  final v = unwrapCell(cell);
  if (v is int) return v;
  if (v is double) {
    return v.isFinite && v == v.truncateToDouble() ? v.toInt() : null;
  }
  if (v is String) {
    final s = _stripPlus(v.trim());
    return s.isEmpty ? null : int.tryParse(s);
  }
  return null;
}

/// Like [parseExplorerInt], without the 64-bit limit.
BigInt? parseExplorerBigInt(Object? cell) {
  final v = unwrapCell(cell);
  if (v is int) return BigInt.from(v);
  if (v is double) {
    return v.isFinite && v == v.truncateToDouble() ? BigInt.from(v) : null;
  }
  if (v is String) {
    final s = _stripPlus(v.trim());
    return s.isEmpty ? null : BigInt.tryParse(s);
  }
  return null;
}

/// A decimal from a typed or raw cell, including the explorer's
/// `"9.1558504 E-2"` notation. Returns null for `""` and non-numbers.
double? parseExplorerDecimal(Object? cell) {
  final v = unwrapCell(cell);
  if (v is num) return v.toDouble();
  if (v is String) {
    final s = _stripPlus(v.replaceAll(RegExp(r'\s'), ''));
    return s.isEmpty ? null : double.tryParse(s);
  }
  return null;
}

/// A UTC time from unix seconds (`1791271756`, `1791271756.0`, or a string).
DateTime? parseExplorerTimestamp(Object? cell) {
  final v = unwrapCell(cell);
  final num? seconds = v is num ? v : (v is String ? num.tryParse(v) : null);
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    (seconds * 1000).round(),
    isUtc: true,
  );
}

String _stripPlus(String s) => s.startsWith('+') ? s.substring(1) : s;
