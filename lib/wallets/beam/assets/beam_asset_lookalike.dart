/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// What on-chain asset text *looks like*, so a copy of a verified asset is
/// caught however it is spelt.
///
/// Anyone can mint an asset and name it anything. A copy of FOMO rarely
/// spells it "FOMO": it uses Cyrillic О and М (`FОМО`), Greek capitals
/// (`ΒΕΑΜ`), fullwidth or mathematical letters (`ＦＯＭＯ`, `𝐅𝐎𝐌𝐎`), digits
/// for letters (`F0M0`), accents (`FÖMÖ`), an extra letter (`wFOMO`,
/// `FOOMO`), a filler word (`FOMO Token`) or Campfire's own id label
/// (`Pepe #174`). [skeleton] reduces text to the Latin capitals it reads
/// as, and [copiedKey] compares those skeletons.
abstract final class BeamLookalike {
  /// Letters from other scripts (and Latin variants Unicode does not
  /// decompose) that render like a Latin letter in common fonts. Keys are
  /// code points; values the Latin capital(s) they read as. A subset of
  /// Unicode TR39's confusables, chosen for what fits an asset ticker.
  static const Map<int, String> _latinLookalikes = {
    // Cyrillic capitals.
    0x0410: 'A', 0x0412: 'B', 0x0421: 'C', 0x0415: 'E', 0x041D: 'H', //
    0x0406: 'I', 0x0408: 'J', 0x041A: 'K', 0x041C: 'M', 0x041E: 'O', //
    0x0420: 'P', 0x0405: 'S', 0x0422: 'T', 0x0425: 'X', 0x0423: 'Y', //
    0x04AE: 'Y', 0x04BA: 'H', 0x0500: 'D', 0x051A: 'Q', 0x051C: 'W', //
    0x04C0: 'I', 0x042C: 'B', 0x0417: '3', //
    // Cyrillic small letters.
    0x0430: 'A', 0x0432: 'B', 0x0441: 'C', 0x0435: 'E', 0x043D: 'H', //
    0x0456: 'I', 0x0458: 'J', 0x043A: 'K', 0x043C: 'M', 0x043E: 'O', //
    0x0440: 'P', 0x0455: 'S', 0x0442: 'T', 0x0445: 'X', 0x0443: 'Y', //
    0x04AF: 'Y', 0x04BB: 'H', 0x0501: 'D', 0x051B: 'Q', 0x051D: 'W', //
    0x04CF: 'I', 0x044C: 'B', 0x0437: '3', //
    // Greek capitals.
    0x0391: 'A', 0x0392: 'B', 0x0395: 'E', 0x0396: 'Z', 0x0397: 'H', //
    0x0399: 'I', 0x039A: 'K', 0x039C: 'M', 0x039D: 'N', 0x039F: 'O', //
    0x03A1: 'P', 0x03A4: 'T', 0x03A5: 'Y', 0x03A7: 'X', 0x03F9: 'C', //
    0x037F: 'J', 0x03DC: 'F', //
    // Greek small letters.
    0x03B1: 'A', 0x03B2: 'B', 0x03B3: 'Y', 0x03B9: 'I', 0x03BA: 'K', //
    0x03BD: 'V', 0x03BF: 'O', 0x03C1: 'P', 0x03C4: 'T', 0x03C5: 'U', //
    0x03C7: 'X', 0x03F2: 'C', 0x03F3: 'J', 0x03C9: 'W', 0x03D0: 'B', //
    // Armenian.
    0x0555: 'O', 0x0585: 'O', 0x054D: 'U', 0x057D: 'U', 0x053C: 'L', //
    // Cherokee capitals (look like Latin capitals).
    0x13AA: 'A', 0x13F4: 'B', 0x13DF: 'C', 0x13A0: 'D', 0x13AC: 'E', //
    0x13C0: 'G', 0x13BB: 'H', 0x13AB: 'J', 0x13E6: 'K', 0x13DE: 'L', //
    0x13B7: 'M', 0x13E2: 'P', 0x13D2: 'R', 0x13DA: 'S', 0x13A2: 'T', //
    0x13D9: 'V', 0x13B3: 'W', 0x13C3: 'Z', //
    // Latin small capitals and variants.
    0x1D00: 'A', 0x0299: 'B', 0x1D04: 'C', 0x1D05: 'D', 0x1D07: 'E', //
    0xA730: 'F', 0x0262: 'G', 0x029C: 'H', 0x026A: 'I', 0x1D0A: 'J', //
    0x1D0B: 'K', 0x029F: 'L', 0x1D0D: 'M', 0x0274: 'N', 0x1D0F: 'O', //
    0x1D18: 'P', 0x0280: 'R', 0xA731: 'S', 0x1D1B: 'T', 0x1D1C: 'U', //
    0x1D20: 'V', 0x1D21: 'W', 0x028F: 'Y', 0x1D22: 'Z', //
    0x0131: 'I', 0x0237: 'J', 0x0251: 'A', 0x0261: 'G', 0x00F8: 'O', //
    0x00D8: 'O', 0x0111: 'D', 0x0110: 'D', 0x0127: 'H', 0x0126: 'H', //
    0x0142: 'L', 0x0141: 'L', 0x0167: 'T', 0x0166: 'T', 0x0180: 'B', //
    0x0268: 'I', 0x0289: 'U', 0x00DF: 'B', 0x1E9E: 'B', 0xA7B4: 'B', //
    0x00C6: 'AE', 0x00E6: 'AE', 0x0152: 'OE', 0x0153: 'OE', //
    // Strokes that read as I or l.
    0x007C: 'I', 0x00A6: 'I', 0x01C0: 'I', 0x2223: 'I', //
  };

  /// Combining marks NFKD leaves behind (accents, overlays).
  static bool _isMark(int r) =>
      (r >= 0x0300 && r <= 0x036F) ||
      (r >= 0x1AB0 && r <= 0x1AFF) ||
      (r >= 0x1DC0 && r <= 0x1DFF) ||
      (r >= 0x20D0 && r <= 0x20FF) ||
      (r >= 0xFE20 && r <= 0xFE2F);

  /// Mathematical alphanumerics (U+1D400…U+1D7FF), in case the normaliser
  /// leaves any of them alone: 13 styles of A–Z a–z, then 5 of 0–9.
  static String? _mathAlphanumeric(int r) {
    if (r >= 0x1D400 && r <= 0x1D6A3) {
      final i = (r - 0x1D400) % 52;
      return String.fromCharCode(0x41 + (i < 26 ? i : i - 26));
    }
    if (r >= 0x1D7CE && r <= 0x1D7FF) {
      return String.fromCharCode(0x30 + (r - 0x1D7CE) % 10);
    }
    return null;
  }

  /// [text] as the Latin capitals and digits it reads as: compatibility
  /// forms unfolded (NFKD), accents dropped, look-alike letters of other
  /// scripts mapped to Latin, anything else (spaces, punctuation,
  /// invisible characters) dropped. `FОМО` (Cyrillic) → `FOMO`,
  /// `ΒΕΑΜ` (Greek) → `BEAM`, `Ｆ.Ｏ.Ｍ.Ｏ` → `FOMO`.
  static String skeleton(String text) {
    final out = StringBuffer();
    for (final r in unorm.nfkd(text).runes) {
      if (_isMark(r)) continue;
      if (r >= 0x30 && r <= 0x39) {
        out.writeCharCode(r);
      } else if (r >= 0x41 && r <= 0x5A) {
        out.writeCharCode(r);
      } else if (r >= 0x61 && r <= 0x7A) {
        out.writeCharCode(r - 0x20);
      } else if (_latinLookalikes[r] case final latin?) {
        out.write(latin);
      } else if (_mathAlphanumeric(r) case final latin?) {
        out.write(latin);
      }
    }
    return out.toString();
  }

  /// Characters that stand for each other once rendered: digits for
  /// letters (`F0M0`, `G1GA`, `5HIB`), lower-case `l` for `I`, `rn` for
  /// `m`, `vv` for `w`.
  static const Map<String, String> _fold = {
    '0': 'O', '1': 'I', 'L': 'I', '2': 'Z', '3': 'E', //
    '4': 'A', '5': 'S', '6': 'G', '7': 'T', '8': 'B', //
  };

  /// [skeleton], with look-alike digits and letter pairs folded together,
  /// so that two texts that render alike compare equal.
  static String canonical(String text) {
    final s = skeleton(text).replaceAll('RN', 'M').replaceAll('VV', 'W');
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      out.write(_fold[s[i]] ?? s[i]);
    }
    return out.toString();
  }

  /// Words that make no difference to what a name claims to be:
  /// "FOMO Token", "Official FOMO", "FOMO v2".
  static final Set<String> _filler = {
    for (final w in const [
      'TOKEN', 'TOKENS', 'COIN', 'COINS', 'OFFICIAL', 'REAL', 'NEW', //
      'ORIGINAL', 'VERIFIED', 'THE', 'ON', 'OF', 'CA', 'ASSET', //
      'WRAPPED', 'BRIDGED', 'V1', 'V2', 'V3', 'V4', 'V5', //
    ])
      canonical(w),
  };

  /// `#174`, `＃174`, `# 174`: Campfire's own way of naming an asset by
  /// its number, which no asset may borrow.
  static final RegExp idLabel = RegExp(r'[#＃﹟]\s*(\p{Nd}+)', unicode: true);

  /// The asset numbers [text] claims with a `#…` label.
  static Iterable<int> claimedIds(String text) sync* {
    for (final m in idLabel.allMatches(unorm.nfkd(text))) {
      final id = int.tryParse(m.group(1)!);
      if (id != null) yield id;
    }
  }

  /// Which of [known] (key → its ticker and name) an asset named [name]
  /// with ticker [symbol] copies, or null. In order of confidence:
  ///
  /// 1. its name or ticker reads exactly as a known ticker or name once
  ///    look-alikes are folded (`FОМО`, `F0M0`, `Ｆ.Ｏ.Ｍ.Ｏ`), also after
  ///    filler words are dropped (`FOMO Token`);
  /// 2. it claims a known asset's number (`Pepe #174`);
  /// 3. it is a near miss: its ticker contains a known ticker of 3+
  ///    letters (`wFOMO`, `FOMO2`), a word of its name is a known ticker of
  ///    4+ letters (`Giga Inu`), or it is one letter added, dropped or
  ///    swapped from a known ticker or name of 4+ letters (`FOOMO`,
  ///    `CRWN`, `FMOO`).
  ///
  /// Substitutions are not near misses (`BEAT` is not `BEAM`): look-alike
  /// substitutions are already folded in step 1.
  static K? copiedKey<K>(
    String? name,
    String? symbol,
    Map<K, ({String symbol, String name})> known,
  ) {
    final n = name == null ? '' : canonical(name);
    final s = symbol == null ? '' : canonical(symbol);
    final words = name == null ? const <String>[] : _words(name);
    final core = words.where((w) => !_filler.contains(w)).join();
    final keys = {
      for (final e in known.entries)
        e.key: (
          symbol: canonical(e.value.symbol),
          name: canonical(e.value.name),
        ),
    };

    bool same(String a, String b) => a.isNotEmpty && a == b;
    for (final e in keys.entries) {
      final k = e.value;
      for (final mine in [n, s, core]) {
        if (same(mine, k.symbol) || same(mine, k.name)) return e.key;
      }
    }

    for (final id in [...claimedIds(name ?? ''), ...claimedIds(symbol ?? '')]) {
      for (final key in known.keys) {
        if (key == id) return key;
      }
    }

    // Near misses: the longest known ticker or name wins ("BEAMX2" copies
    // BEAMX, not BEAM).
    K? best;
    var bestLength = 0;
    void consider(K key, String target, bool hit) {
      if (hit && target.length > bestLength) {
        best = key;
        bestLength = target.length;
      }
    }

    for (final e in keys.entries) {
      final k = e.value;
      for (final target in [k.symbol, k.name]) {
        if (target.length >= 3 && s.length > target.length) {
          consider(e.key, target, s.contains(target));
        }
        if (target.length >= 4) {
          consider(e.key, target, words.contains(target));
          for (final mine in [n, s, core]) {
            consider(e.key, target, _oneEditAway(mine, target));
          }
        }
      }
    }
    return best;
  }

  /// [text]'s words (split at anything that is not a letter or digit),
  /// each [canonical].
  static List<String> _words(String text) => [
    for (final w
        in unorm
            .nfkd(text)
            .split(RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true)))
      if (canonical(w) case final c when c.isNotEmpty) c,
  ];

  /// One letter inserted, dropped, or two neighbours swapped; never a
  /// substitution. Both at least 4 letters long.
  static bool _oneEditAway(String a, String b) {
    if (a == b || a.length < 4 || b.length < 4) return false;
    if (a.length == b.length) {
      var i = 0;
      while (i < a.length && a[i] == b[i]) {
        i++;
      }
      return i + 1 < a.length &&
          a[i] == b[i + 1] &&
          a[i + 1] == b[i] &&
          a.substring(i + 2) == b.substring(i + 2);
    }
    final (long, short) = a.length > b.length ? (a, b) : (b, a);
    if (long.length - short.length != 1) return false;
    var i = 0;
    while (i < short.length && long[i] == short[i]) {
      i++;
    }
    return long.substring(i + 1) == short.substring(i);
  }
}
