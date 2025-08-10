#!/usr/bin/env python3
"""
zRouter gas benchmark summary (benchmarks only).

What it does
------------
- Reads a Foundry gas snapshot (or stdin).
- Filters to: ZRouterBenchTest:*
- Pairs each baseline benchmark with its zRouter variant
  - zRouter suffixes matched case-insensitively: (Zrouter | ZRouter | _ZR)
  - Also pairs Universal Router vs zRouter: (_UR vs _ZR)
- Produces a clean summary table and a Markdown file.
- Default output shows only improvements (you can show all/regressions via flags).

Usage
-----
  forge snapshot
  ./scripts/gas_bench_summary.py --snapshot .gas-snapshot

  # from stdin
  forge snapshot | ./scripts/gas_bench_summary.py --stdin

  # show all rows, not just improvements
  ./scripts/gas_bench_summary.py --show all

  # require at least 1500 gas saved to list an improvement
  ./scripts/gas_bench_summary.py --min-savings 1500
"""

from __future__ import annotations
import argparse, re, sys, statistics
from collections import defaultdict
from pathlib import Path
from typing import List, Tuple, Dict

CLASS_FILTER = "ZRouterBenchTest:"

LINE_RE = re.compile(
    r"^(?P<class>[^:]+):(?P<name>[A-Za-z0-9_]+)\(\) \(gas:\s*(?P<gas>\d+)\)\s*$"
)

# Case-insensitive suffixes
ZR_RE = re.compile(r"(zrouter|_zr)$", re.IGNORECASE)
UR_RE = re.compile(r"_ur$", re.IGNORECASE)

def print_ascii_banner():
    vs = r"""
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃             zRouter   ⚡   Uniswap         ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
"""
    yellow = "\033[93m"
    reset = "\033[0m"
    try:
        print(f"{yellow}{vs}{reset}")
    except:
        print(vs)

def read_lines(args) -> List[str]:
    if args.stdin:
        return sys.stdin.read().splitlines()
    p = Path(args.snapshot)
    if not p.exists():
        print(f"snapshot not found: {p}", file=sys.stderr)
        sys.exit(1)
    return p.read_text().splitlines()

def parse_bench_rows(lines: List[str]) -> List[Tuple[str, str, int]]:
    rows = []
    for ln in lines:
        if not ln.startswith(CLASS_FILTER):
            continue
        m = LINE_RE.match(ln.strip())
        if not m:
            continue
        rows.append((m.group("class"), m.group("name"), int(m.group("gas"))))
    return rows

def stem_kind(name: str) -> Tuple[str, str]:
    """Return (stem, kind) where kind ∈ {'base','zr','ur'} for pairing."""
    if ZR_RE.search(name):
        return ZR_RE.sub("", name), "zr"
    if UR_RE.search(name):
        return UR_RE.sub("", name), "ur"
    return name, "base"

def group_pairs(rows):
    groups = defaultdict(lambda: {"base": [], "zr": [], "ur": []})
    for klass, name, gas in rows:
        stem, kind = stem_kind(name)
        groups[stem][kind].append(gas)
    return groups

def prettify_stem(stem: str) -> str:
    """
    Turn stems like:
      testV3SingleExactOutUsdcForToken
    into:
      V3 • single • exact-out • USDC→TOKEN
    Falls back to the raw stem if we can’t confidently parse.
    """
    s = stem
    if not s.startswith("test"):
        return f"`{stem}`"
    s = s[4:]  # strip 'test'

    # tokens
    parts = []
    # AMM / category
    m = re.match(r"(V2toV3|V3toV2|V[234])", s)
    if m:
        parts.append(m.group(1).upper())
        s = s[m.end():]
    # Single/Multi
    m = re.match(r"(Single|Multi)", s)
    if m:
        parts.append(m.group(1).lower())
        s = s[m.end():]
    # ExactIn/ExactOut
    m = re.match(r"(ExactIn|ExactOut)", s)
    if m:
        parts.append("exact-in" if m.group(1).lower()=="exactin".lower() else "exact-out")
        s = s[m.end():]

    # Path heuristic: split CamelCase into tokens, map common symbols
    tokens = re.findall(r"[A-Z][a-z0-9]*", s)
    alias = {
        "Eth":"ETH", "Token":"TOKEN", "Usdc":"USDC", "Usdt":"USDT",
        "For":"→", "To":"→"
    }
    pretty_path = " ".join(alias.get(t, t) for t in tokens).replace("  ", " ").strip()
    pretty_path = pretty_path.replace(" → ", "→")
    if pretty_path:
        parts.append(pretty_path)

    label = " • ".join(parts)
    return label if label else f"`{stem}`"

def summarize(groups, min_savings: int, show: str):
    """
    Build rows:
      type: 'BASE' (baseline vs ZR) or 'UR' (UR vs ZR)
      label: pretty stem
      base_gas, zr_gas, diff, pct
    Filtering controlled by `show`:
      - 'improved' : only improvements (zr < base and savings >= min_savings)
      - 'all'      : show all pairs that exist
      - 'regressed': only regressions (zr > base)
    """
    rows = []

    def maybe_add(kind, stem, base_list, zr_list):
        if not base_list or not zr_list:
            return
        base = min(base_list)
        zr = min(zr_list)
        diff = zr - base
        pct = (diff / base * 100.0) if base else 0.0
        passes = (
            (show == "all") or
            (show == "improved" and diff < 0 and abs(diff) >= min_savings) or
            (show == "regressed" and diff > 0)
        )
        if passes:
            rows.append((kind, stem, base, zr, diff, pct))

    for stem, k in groups.items():
        # Baseline vs zRouter
        maybe_add("BASE", stem, k["base"], k["zr"])
        # UR vs zRouter (pipeline cases)
        maybe_add("UR", stem, k["ur"], k["zr"])

    rows.sort(key=lambda r: (r[4], r[5]))  # primarily by diff (gas), then pct
    return rows

def print_console(rows):
    if not rows:
        print("No benchmark pairs matched the current filter.")
        return

    print("\n=== zRouter Benchmarks — Gas Summary ===")
    print(f"{'Type':4}  {'Scenario':48} {'Baseline':>10} {'zRouter':>10} {'Diff':>10} {'%':>8}")
    for kind, stem, base, zr, diff, pct in rows:
        label = prettify_stem(stem)
        if len(label) > 48:
            label = label[:45] + "..."
        print(f"{kind:4}  {label:48} {base:10,d} {zr:10,d} {diff:10,d} {pct:8.2f}%")

def write_markdown(rows, out_path: str):
    lines = []
    lines.append("# zRouter Gas — Benchmarks\n")
    if rows:
        lines.append("| Type | Scenario | Baseline Gas | zRouter Gas | Diff | % Change |")
        lines.append("|---|---|---:|---:|---:|---:|")
        for kind, stem, base, zr, diff, pct in rows:
            label = prettify_stem(stem)
            lines.append(f"| {kind} | {label} | {base:,} | {zr:,} | {diff:+,} | {pct:+.2f}% |")
    else:
        lines.append("_No benchmark pairs matched the current filter._")
    Path(out_path).write_text("\n".join(lines) + "\n")
    print(f"\nWrote Markdown: {out_path}")

def print_summary_stats(groups):
    """Quick topline: improved / total; med %; best case."""
    improved = []
    total = 0
    for stem, k in groups.items():
        if k["base"] and k["zr"]:
            total += 1
            base = min(k["base"]); zr = min(k["zr"])
            if zr < base:
                improved.append((zr - base) / base * 100.0)
        if k["ur"] and k["zr"]:
            total += 1
            base = min(k["ur"]); zr = min(k["zr"])
            if zr < base:
                improved.append((zr - base) / base * 100.0)
    if total == 0:
        return
    med = statistics.median(improved) if improved else 0.0
    best = min(improved) if improved else 0.0
    print(f"\nSummary: {len(improved)}/{total} improved • median {med:+.2f}% • best {best:+.2f}%")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", default=".gas-snapshot", help="Path to gas snapshot file")
    ap.add_argument("--stdin", action="store_true", help="Read snapshot from stdin")
    ap.add_argument("--out", default="GAS_BENCH_SUMMARY.md", help="Write Markdown here")
    ap.add_argument("--min-savings", type=int, default=0, help="Minimum gas saved to include (improved mode)")
    ap.add_argument("--show", choices=["improved", "all", "regressed"], default="improved",
                    help="Which rows to include in the table")
    args = ap.parse_args()

    lines = read_lines(args)
    rows = parse_bench_rows(lines)
    if not rows:
        print("No ZRouterBenchTest rows found.")
        sys.exit(0)

    groups = group_pairs(rows)
    table = summarize(groups, args.min_savings, args.show)

    print_ascii_banner()
    print_console(table)
    write_markdown(table, args.out)
    print_summary_stats(groups)

if __name__ == "__main__":
    main()
