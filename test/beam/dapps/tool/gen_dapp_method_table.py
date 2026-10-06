#!/usr/bin/env python3
"""Generate lib/wallets/beam/dapps/dapp_method_table.dart from BEAM core.

Reads the wallet-api method declaration macros of a BEAM core checkout and
prints the Dart table of which methods each API version declares and whether
the core lets applications (dApps) call them (`APPS_ALLOWED` /
`APPS_BLOCKED`).

    python3 -I test/beam/dapps/tool/gen_dapp_method_table.py ~/beam \
        > lib/wallets/beam/dapps/dapp_method_table.dart

How the core builds an API instance, which this mirrors:
  * Each version's class derives from the previous one:
    V74Api : V73Api : V72Api : V71Api : V70Api : V61Api : V6Api
    (wallet/api/v*/v*_api.h).
  * Each constructor registers its own macro list with
    BEAM_API_REG_METHOD, and regMethod() overwrites an earlier entry of the
    same name (wallet/api/base/api_base.h). So v6.1's `wallet_status` and
    `invoke_contract` replace v6.0's.
  * 6.2 is served by V61Api (wallet/api/i_wallet_api.cpp), so it has 6.1's
    table.
  * Methods behind BEAM_ATOMIC_SWAP_SUPPORT / BEAM_ASSET_SWAP_SUPPORT are
    included: they are APPS_BLOCKED either way.

Only the standard library is used; nothing is executed from the checkout.
"""

import os
import re
import subprocess
import sys

# (version label, macro file, macro list names declared in that file)
CHAIN = [
    ("6.0", "wallet/api/v6_0/v6_api_defs.h", ["V6_SWAP_METHODS", "V6_API_METHODS"]),
    ("6.1", "wallet/api/v6_1/v6_1_api_defs.h", ["V6_1_API_METHODS"]),
    ("7.0", "wallet/api/v7_0/v7_0_api_defs.h", ["V7_0_API_METHODS"]),
    ("7.1", "wallet/api/v7_1/v7_1_api_defs.h", ["V7_1_API_METHODS"]),
    ("7.2", "wallet/api/v7_2/v7_2_api_defs.h", ["V7_2_ASSETS_SWAP_METHODS"]),
    ("7.3", "wallet/api/v7_3/v7_3_api_defs.h", ["V7_3_API_METHODS"]),
    ("7.4", "wallet/api/v7_4/v7_4_api_defs.h", ["V7_4_API_METHODS"]),
]
ALIASES = {"6.2": "6.1"}
ORDER = ["6.0", "6.1", "6.2", "7.0", "7.1", "7.2", "7.3", "7.4"]

MACRO = re.compile(
    r'macro\(\s*(\w+)\s*,\s*"([a-z0-9_]+)"\s*,\s*(API_READ_ACCESS|API_WRITE_ACCESS)'
    r'\s*,\s*(API_SYNC|API_ASYNC)\s*,\s*(APPS_ALLOWED|APPS_BLOCKED)\s*\)'
)
DEFINE = re.compile(r"#define\s+(\w+)\(macro\)")


def macro_lists(text):
    """Map each `#define NAME(macro)` to the macro(...) entries in its body."""
    lines = text.splitlines()
    out = {}
    i = 0
    while i < len(lines):
        m = DEFINE.search(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        body = [lines[i]]
        while body[-1].rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            body.append(lines[i])
        entries = MACRO.findall("\n".join(body))
        out.setdefault(name, []).extend(entries)
        i += 1
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: gen_dapp_method_table.py <beam core checkout>")
    core = sys.argv[1]
    try:
        tag = subprocess.run(
            ["git", "-C", core, "describe", "--tags", "--exact-match"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        tag = "unknown"

    tables = {}
    current = {}
    for label, rel, names in CHAIN:
        with open(os.path.join(core, rel), encoding="utf-8") as f:
            lists = macro_lists(f.read())
        for name in names:
            if name not in lists:
                sys.exit(f"{rel}: no #define {name}(macro)")
            for _cls, method, _access, _sync, apps in lists[name]:
                current[method] = apps == "APPS_ALLOWED"
        tables[label] = dict(current)
    for alias, target in ALIASES.items():
        tables[alias] = tables[target]

    w = sys.stdout.write
    w("// GENERATED FILE - DO NOT EDIT.\n")
    w("//\n")
    w(f"// From BEAM core tag {tag}, wallet/api/v*/v*_api_defs.h, by\n")
    w("// test/beam/dapps/tool/gen_dapp_method_table.py. Regenerate with:\n")
    w("//\n")
    w("//   python3 -I test/beam/dapps/tool/gen_dapp_method_table.py <core> \\\n")
    w("//       > lib/wallets/beam/dapps/dapp_method_table.dart\n")
    w("//\n")
    w("// test/beam/dapps/dapp_method_gate_test.dart checks this file against\n")
    w("// the checkout when one is present.\n")
    w("\n")
    w("/// Every method each wallet API version declares, mapped to the core's\n")
    w("/// `appsAllowed` flag: true for APPS_ALLOWED, false for APPS_BLOCKED.\n")
    w("const Map<String, Map<String, bool>> dappCoreMethodTable = {\n")
    for label in ORDER:
        w(f"  '{label}': {{\n")
        for method in sorted(tables[label]):
            w(f"    '{method}': {'true' if tables[label][method] else 'false'},\n")
        w("  },\n")
    w("};\n")


if __name__ == "__main__":
    main()
