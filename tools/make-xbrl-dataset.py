#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Trénovací dvojice z výkazů SEC (inline XBRL).

Vyrobí JSONL, které umí načíst obrazovka Načíst dataset (klíče instruction /
input / output). Nic negeneruje model – odpovědi vznikají šablonou nad
otagovanými čísly, takže jsou ověřitelně správné.

    python3 tools/make-xbrl-dataset.py vykazy/ -o dataset.jsonl

Proč zrovna takhle:

* **Výpis faktů je vždycky ve vstupu, ne v odpovědi.** Model se má naučit
  přečíst řádek, který dostal, ne si pamatovat, že NVIDIA měla 215 938. Bez
  toho by na dotaz o jiné firmě vytáhl číslo NVIDIE.
* **Jsou tam i záporné vzorky** – dotazy na rok nebo ukazatel, který v podkladu
  není, s odpovědí „v podkladech to není“. Bez nich se model naučí, že na každý
  dotaz existuje číslo, a začne si je vymýšlet.
* **Jen ukazatele z `CZECH` níž.** Otagovaných je přes tisíc, ale většina má
  názvy, ze kterých se přirozená česká otázka nedá složit.

Vstup: `.htm` soubory tak, jak je stáhneš ze SEC EDGARu (Archives/edgar/data/…).
Parsování odpovídá `Services/InlineXBRL.swift`; když se změní jedno, musí
se i druhé.
"""

from __future__ import annotations

import argparse
import bisect
import html
import json
import random
import re
import sys
from pathlib import Path

# --- ukazatele, na které se dá položit přirozená česká otázka -----------------
# Klíč je lokální jméno tagu, hodnota (název v 1. pádu, název ve 4. pádu).
CZECH: dict[str, tuple[str, str]] = {
    "Revenues": ("tržby", "tržby"),
    "RevenueFromContractWithCustomerExcludingAssessedTax": ("tržby", "tržby"),
    "CostOfRevenue": ("náklady na tržby", "náklady na tržby"),
    "GrossProfit": ("hrubý zisk", "hrubý zisk"),
    "OperatingExpenses": ("provozní náklady", "provozní náklady"),
    "OperatingIncomeLoss": ("provozní zisk", "provozní zisk"),
    "NetIncomeLoss": ("čistý zisk", "čistý zisk"),
    "ResearchAndDevelopmentExpense": ("náklady na výzkum a vývoj", "náklady na výzkum a vývoj"),
    "IncomeTaxExpenseBenefit": ("daň z příjmu", "daň z příjmu"),
    "Assets": ("celková aktiva", "celková aktiva"),
    "AssetsCurrent": ("oběžná aktiva", "oběžná aktiva"),
    "Liabilities": ("celkové závazky", "celkové závazky"),
    "LiabilitiesCurrent": ("krátkodobé závazky", "krátkodobé závazky"),
    "StockholdersEquity": ("vlastní kapitál", "vlastní kapitál"),
    "CashAndCashEquivalentsAtCarryingValue": ("peníze a peněžní ekvivalenty", "peníze a peněžní ekvivalenty"),
    "InventoryNet": ("zásoby", "zásoby"),
    "AccountsReceivableNetCurrent": ("pohledávky", "pohledávky"),
    "NetCashProvidedByUsedInOperatingActivities": ("provozní cash flow", "provozní cash flow"),
    "NetCashProvidedByUsedInInvestingActivities": ("investiční cash flow", "investiční cash flow"),
    "NetCashProvidedByUsedInFinancingActivities": ("finanční cash flow", "finanční cash flow"),
    # NVIDIA i část emitentů používá `PaymentsToAcquireProductiveAssets`; oba tagy
    # znamenají totéž, proto mají stejný český název.
    "PaymentsToAcquirePropertyPlantAndEquipment": ("kapitálové výdaje", "kapitálové výdaje"),
    "PaymentsToAcquireProductiveAssets": ("kapitálové výdaje", "kapitálové výdaje"),
    "EarningsPerShareBasic": ("základní zisk na akcii", "základní zisk na akcii"),
    "EarningsPerShareDiluted": ("zředěný zisk na akcii", "zředěný zisk na akcii"),
}

# Obměny dotazu, ať model nezkamení na jedné formulaci.
ASK = [
    "Kolik byly {acc} za {fy}?",
    "Jaké měla firma {acc} za {fy}?",
    "{nom} za {fy}?",
    "Vyhledej {acc} za {fy}.",
    "Kolik činily {acc} v roce {fy}?",
]
ASK_BREAKDOWN = [
    "Rozepiš {acc} za {fy} po segmentech.",
    "Jaké byly {acc} za {fy} podle segmentů?",
    "{nom} za {fy} po jednotlivých segmentech?",
]
ASK_STATEMENT = [
    "Vypiš {name}.",
    "Můžeš mi vypsat {name}?",
    "Ukaž {name} celý.",
]
STATEMENT_CZECH = {
    "Consolidated Statements of Income": "výkaz zisku a ztráty",
    "Consolidated Balance Sheets": "rozvahu",
    "Consolidated Statements of Cash Flows": "výkaz peněžních toků",
    "Consolidated Statements of Comprehensive Income": "výkaz úplného výsledku",
    "Consolidated Statements of Shareholders Equity": "výkaz změn vlastního kapitálu",
}
STATEMENT_NAMES = list(STATEMENT_CZECH)

GROUP_PREFIX = "## "
SEPARATOR = "\n---\n"


# --- parsování inline XBRL ----------------------------------------------------

def _attr(text: str, name: str) -> str | None:
    match = re.search(rf'{name}="([^"]*)"', text)
    return match.group(1) if match else None


def _contexts(source: str) -> dict[str, dict]:
    result: dict[str, dict] = {}
    cursor = 0
    while True:
        start = source.find('context id="', cursor)
        if start < 0:
            break
        end = source.find("context>", start)
        if end < 0:
            break
        block = source[start + 12:end]
        cursor = end + 8
        quote = block.find('"')
        if quote < 0:
            continue

        def value(open_tag: str) -> str | None:
            i = block.find(open_tag)
            if i < 0:
                return None
            j = block.find("<", i + len(open_tag))
            return block[i + len(open_tag):j].strip() or None if j > 0 else None

        instant = value("instant>")
        members = [m.group(2) for m in re.finditer(r'dimension="([^"]+)"[^>]*>([^<]+)<', block)]
        result[block[:quote]] = {
            "start": value("startDate>"),
            "end": value("endDate>") or instant,
            "instant": instant is not None,
            "members": members,
        }
    return result


def _dei(source: str) -> dict[str, str]:
    result: dict[str, str] = {}
    cursor = 0
    while True:
        mark = source.find("nonNumeric", cursor)
        if mark < 0:
            break
        gt = source.find(">", mark)
        if gt < 0:
            break
        name = _attr(source[mark:gt], "name")
        cursor = gt + 1
        if not name or not name.startswith("dei:"):
            continue
        nxt = source.find("<", gt + 1)
        text = html.unescape(source[gt + 1:nxt]).strip() if nxt > 0 else ""
        key = name.split(":")[-1]
        if text and key not in result:
            result[key] = text
    return result


def _facts(source: str, contexts: dict[str, dict]) -> list[dict]:
    result: list[dict] = []
    cursor = 0
    while True:
        mark = source.find("nonFraction", cursor)
        if mark < 0:
            break
        gt = source.find(">", mark)
        close = source.find("nonFraction>", gt)
        if gt < 0 or close < 0:
            break
        head, body = source[mark:gt], source[gt + 1:close]
        cursor = close + 12
        name, ref = _attr(head, "name"), _attr(head, "contextRef")
        if not name or not ref or ref not in contexts:
            continue

        stripped, inside = "", False
        for character in body:
            if character == "<":
                inside = True
            elif character == ">":
                inside = False
            elif not inside:
                stripped += character

        comma = "comma-decimal" in (_attr(head, "format") or "")
        digits = ""
        for character in stripped:
            if character.isdigit():
                digits += character
            elif character == "-" and not digits:
                digits += character
            elif character == "." and not comma:
                digits += "."
            elif character == "," and comma:
                digits += "."
        if not any(c.isdigit() for c in digits):
            continue

        value = float(digits)
        scale = _attr(head, "scale")
        if scale:
            value *= 10 ** int(scale)
        if _attr(head, "sign") == "-":
            value = -value
        result.append({
            "tag": name.split(":")[-1],
            "ctx": ref,
            "unit": _attr(head, "unitRef") or "",
            "value": value,
            "pos": mark,
        })
    return result


def _days(iso: str) -> int | None:
    parts = iso[:10].split("-")
    if len(parts) != 3:
        return None
    try:
        year, month, day = (int(p) for p in parts)
    except ValueError:
        return None
    shifted = year - (1 if month <= 2 else 0)
    era = (shifted if shifted >= 0 else shifted - 399) // 400
    year_of_era = shifted - era * 400
    day_of_year = (153 * (month + (-3 if month > 2 else 9)) + 2) // 5 + day - 1
    day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
    return era * 146097 + day_of_era - 719468


def _labels(contexts: dict[str, dict], dei: dict[str, str]) -> dict[str, str]:
    ends = [c["end"] for c in contexts.values() if c["end"]]
    document_end = _days(max(ends)) if ends else None
    try:
        focus = int(dei.get("DocumentFiscalYearFocus", ""))
    except ValueError:
        focus = None

    labels: dict[str, str] = {}
    for key, context in contexts.items():
        end = context["end"]
        end_day = _days(end) if end else None
        if end is None or end_day is None:
            continue
        if context["instant"]:
            labels[key] = f"k {end}"
            continue
        start_day = _days(context["start"]) if context["start"] else None
        if start_day is None:
            labels[key] = f"do {end}"
            continue
        year = focus - round((document_end - end_day) / 365.25) if focus and document_end else int(end[:4])
        length = end_day - start_day
        if length >= 300:
            labels[key] = f"FY{year}"
        elif length >= 60:
            labels[key] = f"Q FY{year} ({context['start']}…{end})"
        else:
            labels[key] = f"{context['start']}…{end}"
    return labels


def _statements(source: str, facts: list[dict]) -> list[tuple[int, int, str]]:
    positions = sorted(f["pos"] for f in facts)
    occurrences: list[tuple[int, str]] = []
    for title in STATEMENT_NAMES:
        needle = title.replace(" Shareholders Equity", " Shareholders")
        for match in re.finditer(re.escape(needle), source, re.I):
            occurrences.append((match.start(), title))
    occurrences.sort()

    accepted: list[tuple[int, str]] = []
    used: set[str] = set()
    for index, (start, title) in enumerate(occurrences):
        if title in used:
            continue
        nxt = occurrences[index + 1][0] if index + 1 < len(occurrences) else len(source)
        if bisect.bisect_left(positions, nxt) - bisect.bisect_left(positions, start) < 15:
            continue
        accepted.append((start, title))
        used.add(title)

    result = []
    for index, (start, title) in enumerate(accepted):
        end = accepted[index + 1][0] if index + 1 < len(accepted) else len(source)
        result.append((start, end, title))
    return result


# --- formátování --------------------------------------------------------------

def _spaced(name: str) -> str:
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name)


def _member(qualified: str) -> str:
    name = qualified.split(":")[-1]
    if name.endswith("Member"):
        name = name[:-6]
    return _spaced(name)


def _grouped(value: float, decimals: int = 0) -> str:
    text = f"{value:,.{decimals}f}".replace(",", "\u00a0")
    return text.replace(".", ",") if decimals else text


def _format(value: float, unit: str) -> str:
    lower = unit.lower()
    if lower in ("usd", "eur", "gbp"):
        if abs(value) >= 1_000_000:
            return _grouped(value / 1_000_000) + f" mil. {unit.upper()}"
        return _grouped(value) + f" {unit.upper()}"
    if lower == "shares":
        if abs(value) >= 1_000_000:
            return _grouped(value / 1_000_000, 1) + " mil. ks"
        return _grouped(value) + " ks"
    if "pershare" in lower:
        return _grouped(value, 2) + " na akcii"
    return _grouped(value) if abs(value) >= 1000 else f"{value:g}".replace(".", ",")


# --- tabulka faktů ------------------------------------------------------------

def fact_table(source: str, name: str):
    """Stejný výpis, jaký appka posílá do promptu, plus fakta pro generování."""
    contexts = _contexts(source)
    dei = _dei(source)
    facts = _facts(source, contexts)
    if len(facts) < 20 or not contexts:
        return None
    labels = _labels(contexts, dei)
    statements = _statements(source, facts)

    seen: set[tuple] = set()
    groups: dict[str, list[str]] = {title: [] for _, _, title in statements}
    other: list[str] = []
    rows: list[dict] = []

    for fact in facts:
        context = contexts[fact["ctx"]]
        period = labels.get(fact["ctx"])
        if period is None:
            continue
        breakdown = " / ".join(_member(m) for m in context["members"])
        key = (fact["tag"], period, breakdown, round(fact["value"], 4))
        if key in seen:
            continue
        seen.add(key)

        parts = [_spaced(fact["tag"]), period]
        if breakdown:
            parts.append(breakdown)
        parts.append(_format(fact["value"], fact["unit"]))
        line = " | ".join(parts)

        group = None
        for start, end, title in statements:
            if start <= fact["pos"] < end:
                group = title
                break
        (groups[group] if group else other).append(line)
        rows.append({
            "tag": fact["tag"], "period": period, "breakdown": breakdown,
            "line": line, "unit": fact["unit"], "value": fact["value"], "group": group,
        })

    body: list[str] = []
    for _, _, title in statements:
        if groups[title]:
            body.append(GROUP_PREFIX + title)
            body.extend(groups[title])
    if other:
        if body:
            body.append(GROUP_PREFIX + "Ostatní údaje")
        body.extend(sorted(other))
    if not body:
        return None

    periods: dict[str, str] = {}
    for key, context in contexts.items():
        label = labels.get(key, "")
        if label.startswith("FY") and label not in periods and context["start"]:
            periods[label] = f"{label} = {context['start']}…{context['end']}"

    identity = [dei.get("EntityRegistrantName"), dei.get("DocumentType")]
    heading = [f"[Otagovaná čísla (XBRL) ze souboru „{name}“ – přesné hodnoty tak, "
               "jak je firma sama označila]"]
    if any(identity):
        heading.append("Zdroj: " + ", ".join(x for x in identity if x))
    if periods:
        heading.append("Období: " + " · ".join(periods[k] for k in sorted(periods, reverse=True)))
    heading.append("Řádek: ukazatel | období | rozpad (segment / region) | hodnota")
    heading.append("Pozor: rozpady se navzájem překrývají a nesčítají se – "
                   "jeden ukazatel je rozepsaný po segmentech, po regionech i po trzích zvlášť.")

    return {
        "heading": "\n".join(heading),
        "body": body,
        "rows": rows,
        "groups": groups,
        "company": dei.get("EntityRegistrantName", name),
    }


# --- vzorky -------------------------------------------------------------------

def _excerpt(heading: str, lines: list[str], budget: int = 1200) -> str:
    picked: list[str] = []
    used = 0
    for line in lines:
        if used + len(line) > budget:
            break
        used += len(line) + 1
        picked.append(line)
    return heading + "\n" + "\n".join(picked)


def samples(table: dict, rng: random.Random) -> list[dict]:
    out: list[dict] = []
    heading = table["heading"]
    rows = table["rows"]

    # 1. Jedno číslo. Do vstupu jde výběr, který by udělala appka: řádky téhož
    #    ukazatele napříč obdobími i rozpady.
    by_tag: dict[str, list[dict]] = {}
    for row in rows:
        by_tag.setdefault(row["tag"], []).append(row)

    for tag, czech in CZECH.items():
        group = by_tag.get(tag)
        if not group:
            continue
        nominative, accusative = czech
        plain = [r for r in group if not r["breakdown"] and r["period"].startswith(("FY", "k "))]
        for row in plain:
            lines = [r["line"] for r in group]
            rng.shuffle(lines)
            out.append({
                "instruction": rng.choice(ASK).format(
                    nom=nominative.capitalize(), acc=accusative, fy=row["period"]),
                "input": _excerpt(heading, lines),
                "output": f"{nominative.capitalize()} za {row['period']}: {_format(row['value'], row['unit'])}.",
            })

        # 2. Rozpad po segmentech.
        segments = [r for r in group if "Segment" in r["breakdown"] and r["period"].startswith("FY")]
        periods = sorted({r["period"] for r in segments}, reverse=True)
        for period in periods[:2]:
            picked = [r for r in segments if r["period"] == period]
            if len(picked) < 2:
                continue
            answer = "\n".join(f"- {r['breakdown']}: {_format(r['value'], r['unit'])}" for r in picked)
            out.append({
                "instruction": rng.choice(ASK_BREAKDOWN).format(
                    nom=nominative.capitalize(), acc=accusative, fy=period),
                "input": _excerpt(heading, [r["line"] for r in group], budget=2000),
                "output": f"{nominative.capitalize()} za {period} po segmentech:\n{answer}",
            })

    # 3. Celý výkaz. Odpověď je tabulka všech řádků v pořadí dokumentu.
    for title, lines in table["groups"].items():
        if len(lines) < 5:
            continue
        czech = STATEMENT_CZECH.get(title, title)
        table_rows = "\n".join(f"| {l.replace(' | ', ' | ')} |" for l in lines)
        out.append({
            "instruction": rng.choice(ASK_STATEMENT).format(name=czech),
            "input": heading + "\n" + GROUP_PREFIX + title + "\n" + "\n".join(lines),
            "output": f"| Ukazatel | Období | Hodnota |\n|---|---|---|\n{table_rows}",
        })

    # 4. Záporné vzorky. Bez nich se model naučí, že číslo existuje vždycky.
    known_years = {r["period"] for r in rows if r["period"].startswith("FY")}
    missing_year = f"FY{max(int(y[2:]) for y in known_years) + 1}" if known_years else None
    if missing_year:
        for tag in list(CZECH)[:6]:
            group = by_tag.get(tag)
            if not group:
                continue
            nominative, accusative = CZECH[tag]
            out.append({
                "instruction": rng.choice(ASK).format(
                    nom=nominative.capitalize(), acc=accusative, fy=missing_year),
                "input": _excerpt(heading, [r["line"] for r in group]),
                "output": f"{nominative.capitalize()} za {missing_year} v podkladech nejsou – "
                          f"výpis má jen {', '.join(sorted(known_years, reverse=True))}.",
            })

    # Pozor na synonyma: `Revenues` a `RevenueFromContractWithCustomer…` mají oba
    # český název „tržby“. Kdyby se bral jen chybějící tag, vznikl by vzorek
    # „Jaké byly tržby za FY2026?“ → „tržby ve výpisu nejsou“, přestože tam jsou.
    present_names = {CZECH[t][0] for t in by_tag if t in CZECH}
    missing_tags = [t for t in CZECH if t not in by_tag and CZECH[t][0] not in present_names][:4]
    for tag in missing_tags:
        nominative, accusative = CZECH[tag]
        period = sorted(known_years, reverse=True)[0] if known_years else "FY2026"
        out.append({
            "instruction": rng.choice(ASK).format(
                nom=nominative.capitalize(), acc=accusative, fy=period),
            "input": _excerpt(heading, [r["line"] for r in rows[:40]]),
            "output": f"{nominative.capitalize()} ve výpisu otagovaných čísel nejsou.",
        })

    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", nargs="+", type=Path, help="soubory .htm nebo složky s nimi")
    parser.add_argument("-o", "--out", type=Path, default=Path("xbrl-dataset.jsonl"))
    parser.add_argument("--seed", type=int, default=42, help="kvůli opakovatelnosti běhu")
    parser.add_argument("--max-per-file", type=int, default=0, help="0 = bez omezení")
    args = parser.parse_args()

    files: list[Path] = []
    for item in args.source:
        files.extend(sorted(item.rglob("*.htm")) if item.is_dir() else [item])
    if not files:
        print("Nenašel jsem žádný .htm.", file=sys.stderr)
        return 1

    rng = random.Random(args.seed)
    collected: list[dict] = []
    total = 0
    with args.out.open("w", encoding="utf-8") as output:
        for path in files:
            source = path.read_text(encoding="utf-8", errors="ignore")
            table = fact_table(source, path.name)
            if table is None:
                print(f"  přeskakuji {path.name} – není inline XBRL")
                continue
            rows = samples(table, rng)
            if args.max_per_file:
                rng.shuffle(rows)
                rows = rows[:args.max_per_file]
            collected.extend(rows)
            print(f"  {path.name}: {len(rows)} vzorků ({table['company']})")

        # Zamíchat je nutné, ne kosmetické. Appka bere validační část z konce
        # souboru; bez zamíchání by v ní byly jen poslední druhy vzorků z posledního
        # výkazu (celé výkazy a záporné dotazy) a validační ztráta by měřila něco
        # úplně jiného než trénink.
        rng.shuffle(collected)
        for row in collected:
            output.write(json.dumps(row, ensure_ascii=False) + "\n")
        total = len(collected)

    print(f"\n{total} vzorků → {args.out}")
    print("Zkopíruj do složky appky v Souborech a načti v Trénink › Načíst dataset.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
