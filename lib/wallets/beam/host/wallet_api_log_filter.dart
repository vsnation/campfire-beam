/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Decides which of wallet-api's console lines may be kept in a file.
///
/// At info level wallet-api prints the wallet's history: every address it
/// loads or creates (`WalletID …`, `New Wallet address generated: …`,
/// `Generated offline address: …`, `wallet_db.cpp:7815-7843`), every coin
/// (`CoinID: … Confirmed`) and every transaction with its amount, fee and
/// both endpoints (`<txid> Sending 0.1 BEAM (fee: …), my EP …, peer EP …`,
/// `simple_transaction.cpp:283-293`). A file holding that is the wallet's
/// history in plain text outside `wallet.db` (ARCHITECTURE.md §5, Logs:
/// never amounts and addresses together).
///
/// The host still reads every line to follow the startup. What is written
/// to the wallet's log file is only:
///
/// * warnings and errors (`W`, `E`, `C`) and untagged lines (the config
///   path, exceptions);
/// * info lines that start with one of [infoAllowed]: startup markers and
///   chain heights, nothing about this wallet;
/// * the tab-indented fork list under `Rules signature:` (which consensus
///   the binary follows);
///
/// and in every kept line, each run of 32 or more letters and digits (an
/// address, wallet ID, endpoint, transaction ID or key) is replaced. A line
/// that mentions sending, receiving, an endpoint, a coin or a generated
/// address is dropped whatever its level.
library;

/// Filters one wallet-api process's console output. Stateful only for the
/// rules signature's continuation lines; use one per process.
class BeamWalletApiLogFilter {
  /// Info messages worth keeping. Each is a fixed phrase followed by
  /// public data (a path in the app's own folder, a version, a height and a
  /// short block hash, a port).
  static const List<String> infoAllowed = [
    'Wallet API config read from',
    'Wallet API common config read from',
    'Beam Wallet API ',
    'Rules signature:',
    'ACL file successfully loaded',
    'wallet successfully opened',
    'Start server on',
    'cannot start server',
    'Sync up to ',
    'Synchronizing with node:',
    'Current state is ',
    'Tip has not been changed',
    'Rolled back to ',
    'It seems that last known blockchain tip is not up to date',
    'peer disconnected',
  ];

  /// `<level> <yyyy-mm-dd.hh:mm:ss.mmm> ` and, in builds that add it,
  /// `(func, file:line) `. Levels as `utility/logger.h` tags them.
  static final RegExp _header = RegExp(
    r'^([~VDIWEC]) \d{4}-\d{2}-\d{2}\.\d{2}:\d{2}:\d{2}(?:\.\d+)? '
    r'(?:\([^)]*\) )?',
  );

  static final RegExp _history = RegExp(
    r' (?:Sending|Receiving|Splitting) '
    r'|\b(?:my|peer) EP\b'
    r'|\(aid, amount\)'
    r'|WalletID'
    r'|Endpoint\s*='
    r'|CoinID'
    r'|Shielded output'
    r'|[Gg]enerated[^\n]*address',
  );

  static final RegExp _longToken = RegExp(r'[A-Za-z0-9]{32,}');

  bool _inRules = false;

  /// The form of [line] to write, or null to write nothing. [line] has
  /// already been through the host's secret redaction.
  String? fileLine(String line) {
    if (line.startsWith('\t')) {
      return _inRules ? _scrub(line) : null;
    }
    _inRules = false;
    if (line.trim().isEmpty) return null;
    final m = _header.firstMatch(line);
    final message = m == null ? line : line.substring(m.end);
    if (_history.hasMatch(message)) return null;
    if (m != null) {
      final level = m.group(1)!;
      if (level == 'I' && message.startsWith('Rules signature:')) {
        _inRules = true;
      }
      final keep = switch (level) {
        'W' || 'E' || 'C' => true,
        'I' => infoAllowed.any(message.startsWith),
        _ => false, // debug, verbose, unknown
      };
      if (!keep) return null;
    }
    return _scrub(line);
  }

  static String _scrub(String line) =>
      line.replaceAll(_longToken, '[redacted]');
}
