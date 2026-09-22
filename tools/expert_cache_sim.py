#!/usr/bin/env python3
"""Přehraje záznam výběru expertů (.axtr z appky) při různých velikostech cache.

Stejný výpočet jako `ExpertCacheSimulator` v appce, jen na počítači a s volitelnými
velikostmi. Princip je z kimi-k3-in-c (tools/sim_cache.py): routing nezávisí na cache,
takže jeden záznam jde přehrát pro libovolnou kapacitu a politiku.

    python tools/expert_cache_sim.py Qwen3-30B-A3B-20260922-204512.axtr
    python tools/expert_cache_sim.py trace.axtr --sizes 0.5 1 1.5 2 3 --all-phases

Politiky:
  LRU     vyhodí nejdéle nepoužitého – zhruba to, co dělá page cache iOS
  LFU     vyhodí nejméně často použitého (četnost od začátku záznamu)
  Belady  vyhodí toho, kdo bude potřeba nejpozději – strop, ne politika (zná budoucnost)
  strop   povinné výpadky: každého experta je potřeba aspoň jednou přečíst

Nepotřebuje žádné balíčky.
"""

from __future__ import annotations

import argparse
import heapq
import struct
import sys
from collections import Counter, OrderedDict
from dataclasses import dataclass, field

MAGIC = b"AXTR"
UNMEASURED = 0xFFFF
GB = 1024 ** 3
MB = 1024 ** 2
DEFAULT_SIZES_GB = [0.25, 0.5, 1, 1.5, 2, 3, 4, 6]


@dataclass
class Event:
    layer: int
    tokens: int
    resident: int | None
    experts: list[int]


@dataclass
class Trace:
    expert_count: int
    slice_bytes: list[int]
    model_name: str
    residency_measured: bool
    events: list[Event]


def read_trace(path: str) -> Trace:
    data = open(path, "rb").read()
    if data[:4] != MAGIC:
        sys.exit(f"{path}: není záznam expertů (.axtr)")
    version, expert_count, layer_count, flags = struct.unpack_from("<4H", data, 4)
    if version != 1:
        sys.exit(f"{path}: nepodporovaná verze {version}")
    offset = 12
    slices = list(struct.unpack_from(f"<{layer_count}I", data, offset))
    offset += 4 * layer_count
    (name_length,) = struct.unpack_from("<H", data, offset)
    offset += 2
    name = data[offset:offset + name_length].decode("utf-8", "replace")
    offset += name_length

    events: list[Event] = []
    while offset + 8 <= len(data):
        layer, tokens, count, resident = struct.unpack_from("<4H", data, offset)
        if offset + 8 + 2 * count > len(data):
            break  # useknutý konec
        experts = list(struct.unpack_from(f"<{count}H", data, offset + 8))
        offset += 8 + 2 * count
        if layer >= layer_count or any(e >= expert_count for e in experts):
            continue
        events.append(Event(layer, tokens, None if resident == UNMEASURED else resident, experts))
    return Trace(expert_count, slices, name, bool(flags & 1), events)


@dataclass
class PhaseStats:
    requests: int = 0
    hits: int = 0
    miss_bytes: int = 0

    @property
    def hit_rate(self) -> float:
        return self.hits / self.requests if self.requests else 0.0


@dataclass
class Result:
    decode: PhaseStats = field(default_factory=PhaseStats)
    prefill: PhaseStats = field(default_factory=PhaseStats)


def flatten(trace: Trace):
    """Posloupnost požadavků: (klíč, velikost, je_generování)."""
    stream = []
    for event in trace.events:
        size = trace.slice_bytes[event.layer]
        decode = event.tokens == 1
        for expert in event.experts:
            stream.append((event.layer * trace.expert_count + expert, size, decode))
    return stream


def next_uses(stream) -> list[int]:
    """Pro každý požadavek index dalšího požadavku na stejný klíč (len = už nikdy)."""
    result = [0] * len(stream)
    last: dict[int, int] = {}
    for index in range(len(stream) - 1, -1, -1):
        key = stream[index][0]
        result[index] = last.get(key, len(stream))
        last[key] = index
    return result


def simulate(stream, capacity: int, policy: str, nxt: list[int] | None = None) -> Result:
    result = Result()
    resident: dict[int, int] = {}  # klíč → velikost
    used = 0
    lru: OrderedDict[int, None] = OrderedDict()
    freq: Counter[int] = Counter()
    last_use: dict[int, int] = {}
    next_use: dict[int, int] = {}
    heap: list[tuple] = []

    for index, (key, size, decode) in enumerate(stream):
        phase = result.decode if decode else result.prefill
        phase.requests += 1
        hit = key in resident
        if hit:
            phase.hits += 1
        else:
            phase.miss_bytes += size

        # Evidence politiky – musí proběhnout i u zásahu.
        if policy == "LRU":
            lru[key] = None
            lru.move_to_end(key)
        elif policy == "LFU":
            freq[key] += 1
            last_use[key] = index
            heapq.heappush(heap, (freq[key], index, key))
        elif policy == "Belady":
            next_use[key] = nxt[index]
            heapq.heappush(heap, (-nxt[index], key))

        if not hit:
            resident[key] = size
            used += size

        # Vyhazovat, dokud se nevejde (může vyhodit i právě vložený klíč = obejití cache).
        while used > capacity:
            if policy == "LRU":
                victim, _ = lru.popitem(last=False)
                if victim not in resident:
                    continue
            elif policy == "LFU":
                count, when, victim = heapq.heappop(heap)
                if victim not in resident or freq[victim] != count or last_use[victim] != when:
                    continue
            else:
                negative, victim = heapq.heappop(heap)
                if victim not in resident or next_use[victim] != -negative:
                    continue
            used -= resident.pop(victim)
            if policy == "LRU":
                lru.pop(victim, None)
    return result


def compulsory(stream) -> Result:
    """Nekonečná cache: jediné výpadky jsou první požadavky na každý klíč."""
    result = Result()
    seen: set[int] = set()
    for key, size, decode in stream:
        phase = result.decode if decode else result.prefill
        phase.requests += 1
        if key in seen:
            phase.hits += 1
        else:
            phase.miss_bytes += size
            seen.add(key)
    return result


def decode_tokens(trace: Trace) -> int:
    decode_layers = [e.layer for e in trace.events if e.tokens == 1]
    if not decode_layers:
        return 0
    first = min(decode_layers)
    return sum(1 for e in trace.events if e.tokens == 1 and e.layer == first)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("trace")
    parser.add_argument("--sizes", type=float, nargs="+", default=DEFAULT_SIZES_GB, help="velikosti cache v GB")
    parser.add_argument("--all-phases", action="store_true", help="zásah počítat i z prefillu (výchozí jen generování)")
    args = parser.parse_args()

    trace = read_trace(args.trace)
    stream = flatten(trace)
    if not stream:
        sys.exit("záznam je prázdný")
    nxt = next_uses(stream)
    tokens = decode_tokens(trace)
    keys = {key: size for key, size, _ in stream}
    distinct_bytes = sum(keys.values())

    # Jen generování (prefill cache jen zahřívá), pokud záznam generování vůbec má.
    decode_only = not args.all_phases and any(decode for *_, decode in stream)

    def pick(result: Result) -> PhaseStats:
        if not decode_only:
            both = PhaseStats()
            for phase in (result.decode, result.prefill):
                both.requests += phase.requests
                both.hits += phase.hits
                both.miss_bytes += phase.miss_bytes
            return both
        return result.decode

    decode_requests = sum(1 for *_, d in stream if d)
    print(f"model      : {trace.model_name}")
    print(f"požadavky  : {len(stream)} ({decode_requests} při generování, {tokens} vygenerovaných tokenů)")
    print(f"experti    : {len(keys)} různých z {trace.expert_count * sum(1 for s in trace.slice_bytes if s)}"
          f" · všichni použití {distinct_bytes / GB:.2f} GB")
    if trace.residency_measured:
        measured = [e for e in trace.events if e.resident is not None and (not decode_only or e.tokens == 1)]
        requested = sum(len(e.experts) for e in measured)
        if requested:
            print(f"naměřeno   : zásah page cache {sum(e.resident for e in measured) / requested * 100:.1f} %"
                  " (mincore před předčtením, iOS)")
    counts = Counter(key for key, _, decode in stream if decode or not decode_only)
    if counts:
        top = sorted(counts.values(), reverse=True)
        tenth = max(1, len(top) // 10)
        print(f"nerovnost  : nejčastějších 10 % expertů = {sum(top[:tenth]) / sum(top) * 100:.1f} % požadavků")
    ceiling = pick(compulsory(stream))
    print(f"strop      : {ceiling.hit_rate * 100:.1f} % (povinné výpadky – víc nedá žádná politika)")
    print()

    phase_label = "generování" if decode_only else "vše"
    per_token = tokens > 0 and decode_only
    header = f"{'CACHE':>8} {'LRU':>8} {'LFU':>8} {'BELADY':>8}"
    if per_token:
        header += f" {'MB/TOK LRU':>11} {'MB/TOK BEL.':>12}"
    print(f"zásah cache ({phase_label})")
    print(header)
    print("-" * len(header))
    capacities = sorted({int(size * GB) for size in args.sizes if size * GB < distinct_bytes})
    capacities.append(distinct_bytes)
    for capacity in capacities:
        rows = {policy: pick(simulate(stream, capacity, policy, nxt)) for policy in ("LRU", "LFU", "Belady")}
        label = "vše" if capacity == distinct_bytes else f"{capacity / GB:g} GB"
        line = f"{label:>8}" + "".join(f" {rows[p].hit_rate * 100:7.1f}%" for p in ("LRU", "LFU", "Belady"))
        if per_token:
            line += f" {rows['LRU'].miss_bytes / tokens / MB:11.0f} {rows['Belady'].miss_bytes / tokens / MB:12.0f}"
        print(line)
    print()
    print("Belady zná budoucnost – je to strop pro danou velikost, ne použitelná politika.")
    print("Velký rozdíl LRU vs. Belady = páka je v politice (co držet), ne ve velikosti cache.")


if __name__ == "__main__":
    main()
