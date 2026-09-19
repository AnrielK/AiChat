#!/usr/bin/env python3
"""
Přeuspořádá tenzory v GGUF souboru MoE modelu tak, aby všechno kromě routovaných
expertů leželo v souboru pohromadě na začátku a experti až za tím.

Proč: appka (AIChat) u MoE modelů nechává experty na CPU namapované ze souboru a na
Metal dává jen hustou část. Metal ale umí sdílet namapovaný soubor jen jako souvislý
buffer od prvního po poslední tenzor pro GPU. V běžném GGUF se attention a experti
střídají vrstvu po vrstvě, takže by buffer pokryl celý soubor a iOS by ho musel držet
v RAM. Po přeuspořádání pokryje jen hustou část (u Qwen3-30B-A3B asi 1 GB).

Obsah tenzorů ani metadata se nemění, jen pořadí dat a seznamu tenzorů v hlavičce
(llama.cpp vyžaduje, aby seznam tenzorů šel ve stejném pořadí jako data).
Nepotřebuje žádné balíčky. Na výstup je potřeba stejně místa jako zabírá vstup.

    python gguf_moe_reorder.py vstup.gguf vystup.gguf

Soubor přeuspořádaný starší verzí skriptu (llama.cpp ho odmítne načíst) se dá opravit
na místě – přepíše se jen hlavička, trvá to pár sekund:

    python gguf_moe_reorder.py --oprava soubor.gguf
"""
import os
import re
import struct
import sys

EXPERT = re.compile(r"\.ffn_(up|down|gate|gate_up)_(ch|)exps")
CHUNK = 64 * 1024 * 1024

# velikost skalárních typů hodnot v metadatech
SCALAR = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
TYPE_STRING, TYPE_ARRAY, TYPE_UINT32 = 8, 9, 4


class Reader:
    def __init__(self, f):
        self.f = f

    def read(self, n):
        data = self.f.read(n)
        if len(data) != n:
            raise ValueError("neočekávaný konec souboru")
        return data

    def u32(self):
        return struct.unpack("<I", self.read(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.read(8))[0]

    def string(self):
        return self.read(self.u64()).decode("utf-8")

    def skip_value(self, vtype):
        if vtype in SCALAR:
            self.read(SCALAR[vtype])
        elif vtype == TYPE_STRING:
            self.read(self.u64())
        elif vtype == TYPE_ARRAY:
            item_type, count = self.u32(), self.u64()
            if item_type in SCALAR:
                self.read(SCALAR[item_type] * count)
            else:
                for _ in range(count):
                    self.skip_value(item_type)
        else:
            raise ValueError(f"neznámý typ hodnoty {vtype}")


def align(value, alignment):
    return (value + alignment - 1) // alignment * alignment


def read_layout(path):
    with open(path, "rb") as f:
        r = Reader(f)
        if r.read(4) != b"GGUF":
            sys.exit("Není to GGUF soubor.")
        version = r.u32()
        if version < 2:
            sys.exit(f"GGUF verze {version} není podporovaná.")
        n_tensors, n_kv = r.u64(), r.u64()

        alignment = 32
        for _ in range(n_kv):
            key = r.string()
            vtype = r.u32()
            if key == "general.alignment" and vtype == TYPE_UINT32:
                alignment = r.u32()
            else:
                r.skip_value(vtype)

        infos_start = f.tell()
        tensors = []  # [jméno, začátek záznamu, konec záznamu, offset dat]
        for _ in range(n_tensors):
            entry_start = f.tell()
            name = r.string()
            n_dims = r.u32()
            r.read(8 * n_dims + 4)  # rozměry + typ
            offset = r.u64()
            tensors.append([name, entry_start, f.tell(), offset])

        infos_end = f.tell()
        data_start = align(infos_end, alignment)
        f.seek(0)
        header = bytes(f.read(data_start))

    return alignment, infos_start, infos_end, data_start, header, tensors


def build_header(header, infos_start, infos_end, entries):
    """Hlavička se seznamem tenzorů v zadaném pořadí; entries = [(záznam, nový offset)]."""
    infos = bytearray()
    for (name, entry_start, entry_end, _), offset in entries:
        record = bytearray(header[entry_start:entry_end])
        struct.pack_into("<Q", record, len(record) - 8, offset)
        infos += record
    assert len(infos) == infos_end - infos_start
    return header[:infos_start] + bytes(infos) + header[infos_end:]


def repair(path):
    """Seřadí seznam tenzorů podle offsetu dat – data se nehýbou, přepíše se jen hlavička."""
    alignment, infos_start, infos_end, data_start, header, tensors = read_layout(path)
    ordered = sorted(tensors, key=lambda t: t[3])
    if ordered == tensors:
        print("Seznam tenzorů už je ve stejném pořadí jako data, není co opravovat.", file=sys.stderr)
        return
    new_header = build_header(header, infos_start, infos_end, [(t, t[3]) for t in ordered])
    with open(path, "r+b") as f:
        f.write(new_header)
    verify(path)
    print("Hlavička opravena.", file=sys.stderr)


def verify(path):
    """Stejná kontrola jako gguf.cpp: offsety musí jít za sebou v pořadí seznamu tenzorů."""
    alignment, _, _, data_start, _, tensors = read_layout(path)
    size = os.path.getsize(path)
    expected = 0
    for name, _, _, offset in tensors:
        if offset < expected:
            sys.exit(f"Chyba: tenzor {name} má offset {offset}, očekáváno aspoň {expected}.")
        if offset != align(offset, alignment):
            sys.exit(f"Chyba: tenzor {name} není zarovnaný.")
        expected = offset + 1
    if tensors and data_start + max(t[3] for t in tensors) > size:
        sys.exit("Chyba: data tenzorů přesahují konec souboru.")


def main(src, dst):
    if os.path.abspath(src) == os.path.abspath(dst):
        sys.exit("Výstup musí být jiný soubor než vstup.")
    size = os.path.getsize(src)
    alignment, infos_start, infos_end, data_start, header, tensors = read_layout(src)

    # Délka bloku = do začátku dalšího tenzoru (včetně zarovnání), poslední do konce souboru.
    by_offset = sorted(tensors, key=lambda t: t[3])
    for current, following in zip(by_offset, by_offset[1:] + [None]):
        end = following[3] if following else size - data_start
        current.append(end - current[3])

    experts = [t for t in by_offset if EXPERT.search(t[0])]
    if not experts:
        sys.exit("V souboru nejsou žádní routovaní experti – přeuspořádání nic nezmění.")
    embeddings = [t for t in by_offset if t[0].startswith("token_embd.")]
    dense = [t for t in by_offset if t not in experts and t not in embeddings]
    order = embeddings + dense + experts

    entries = []
    offset = 0
    for tensor in order:
        entries.append((tensor[:4], offset))
        offset = align(offset + tensor[4], alignment)
    new_header = build_header(header, infos_start, infos_end, entries)

    written = 0
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        fout.write(new_header)
        for index, (name, _, _, old_offset, length) in enumerate(order):
            fin.seek(data_start + old_offset)
            remaining = length
            while remaining:
                chunk = fin.read(min(CHUNK, remaining))
                if not chunk:
                    sys.exit(f"Tenzor {name} je useknutý.")
                fout.write(chunk)
                remaining -= len(chunk)
            padding = align(length, alignment) - length
            if padding and index < len(order) - 1:
                fout.write(b"\0" * padding)
            written += length
            print(f"\r{written / size * 100:5.1f} %", end="", file=sys.stderr, flush=True)

    verify(dst)
    dense_bytes = sum(t[4] for t in dense)
    expert_bytes = sum(t[4] for t in experts)
    print(f"\nHotovo: hustá část {dense_bytes / 2**20:.0f} MB pohromadě, "
          f"experti {expert_bytes / 2**20:.0f} MB za ní.", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--oprava":
        repair(sys.argv[2])
    elif len(sys.argv) == 3:
        main(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)
