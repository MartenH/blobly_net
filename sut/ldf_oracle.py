#!/usr/bin/env python3
"""ldf_oracle.py — ldfparser's reading of an LDF, in the line-per-fact form blobly/lindb's
`Ldf.dump()` prints, diffed against blobly's own by running `sut/ldf_dump.v`.

    python3 sut/ldf_oracle.py dbc/lin_demo.ldf            # diff; exit 1 on any difference
    python3 sut/ldf_oracle.py dbc/lin_demo.ldf --print    # ldfparser's lines only
    V=~/v_pin_5f7d4d0/v python3 sut/ldf_oracle.py ...     # the V to run ldf_dump.v with

An independent implementation is the point (see README.md): it compares nodes and their
attributes, frames (id, publisher, length, checksum model), signals (width, init, offset in
frame), encodings, each frame's template, schedule entries and delays, and the frame bytes and
decoded values of sample encodes — every encoding range at its ends and middle, every logical
value, raw values at a scalar's limits, byte arrays, and refusals.

Where the two are not compared as-is, and why:

  - The checksum model is not in ldfparser's model, so the oracle derives it by the same rule
    from ldfparser's node attributes — it checks the inputs, not the rule: 0x3C/0x3D classic;
    a slave's frame in its publisher's model (LIN_protocol, else the file's version), which
    every subscribing slave must share; a master's frame in its subscribing slaves' model,
    the file's where none subscribe, none where LIN 1.x and 2.x slaves both subscribe.
  - ldfparser does not model the protected id a frame tied to an event-triggered frame carries
    in byte 0 (LIN 2.2A 2.3.3.2), so the oracle puts it there itself, from its own parity
    function, in the template and in every encode of such a frame.
  - ldfparser reads a product_id without a variant as variant 0; lindb keeps it absent (`-`),
    so the oracle asks ldfparser's own parse tree whether the variant was written.
  - ldfparser keeps a string's escapes (`"switch \\"on\\""` reads as `switch \\"on\\"`); lindb reads
    `\\x` as `x`, so the oracle unescapes ldfparser's texts the same way before comparing.
  - A text in a request escapes `|`, `=` and `\\` with a backslash (`Ldf.query`).
  - A header statement, Master line or Nodes section given twice: ldfparser keeps the last,
    lindb the first, with a note. The fixtures have none.
  - ldfparser pads unused bits with zeros unless asked; LIN has them recessive (1), so
    the oracle asks (`pad_with_zero=False`).
  - ldfparser's frame-level encode/decode of a byte array THROUGH an encoding is broken in
    0.26.0 (it turns the array into one big-endian integer before the ascii/bcd converter,
    which expects a list), so the oracle applies ldfparser's ascii/bcd converters to the
    byte list itself and packs that with encode_raw/decode_raw.
  - BCD digit packing is not stated by the spec; ldfparser and lindb both put one decimal
    digit per byte, most significant first. Agreement here is agreement of convention.
  - Rounding a physical value to a raw one: ldfparser uses Python's round (half to even),
    lindb rounds half away from zero. The samples are exact raw values, so they do not differ.
  - A signal wider than 16 bits that is not a byte array: the spec limits scalars to 16 bits;
    lindb carries up to 64, ldfparser does not check. The fixture has none.
  - A LIN 1.x file has no Node_attributes; ldfparser makes each slave a node with defaulted
    attributes, lindb makes none, so the oracle prints no `node` line for LIN 1.x.
  - ldfparser 0.26.0 cannot read a LIN 2.0 event-triggered frame without a collision-resolving
    table (`Ev: 0x08, F1, F2;` raises IndexError in its transformer); lindb reads it with
    table `-`. There is no oracle for that form.
  - lindb's `note` lines (what it refused or did not model) have no ldfparser counterpart and
    are left out of the diff; lindb's own tests pin them.

Needs ldfparser (requirements.txt).
"""
import argparse
import difflib
import os
import re
import subprocess
import sys

import ldfparser
from ldfparser.encoding import ASCIIValue, BCDValue, LogicalValue, PhysicalValue
from ldfparser.frame import LinUnconditionalFrame
from ldfparser.schedule import (LinFrameEntry, MasterRequestEntry, SlaveResponseEntry)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def fmt_num(x):
    x = float(x)
    if x == int(x) and abs(x) < 1e15:
        return str(int(x))
    return f'{x:.6f}'.rstrip('0').rstrip('.')


def unesc(t):
    """A string's text with each backslash escape read as the character it escapes."""
    return re.sub(r'\\(.)', r'\1', t) if t else t


def esc(t):
    """A text as a request carries it: `\\`, `|` and `=` escaped."""
    return t.replace('\\', '\\\\').replace('|', '\\|').replace('=', '\\=')


def dash(s):
    return s if s else '-'


def model_of(version):
    return 'classic' if str(version).startswith('1.') else 'enhanced'


def slave_model(ldf, name):
    slave = ldf.slave(name)
    if slave is not None and slave.lin_protocol is not None:
        return model_of(slave.lin_protocol)
    return model_of(ldf.get_protocol_version())


def checksum_for(ldf, f):
    """The checksum model of unconditional frame f, or '-' where no one model serves it."""
    slaves = {s.name for s in ldf.slaves}
    subs = []
    for _, sig in f.signal_map:
        for n in sig.subscribers:
            if n.name in slaves and n.name not in subs:
                subs.append(n.name)
    pub = f.publisher.name
    if pub != ldf.master.name:
        model = slave_model(ldf, pub)
        if any(slave_model(ldf, s) != model for s in subs if s != pub):
            return '-'
        return model
    models = {slave_model(ldf, s) for s in subs}
    if len(models) > 1:
        return '-'
    return models.pop() if models else model_of(ldf.get_protocol_version())


def pid(frame_id):
    b = [(frame_id >> i) & 1 for i in range(6)]
    p0 = b[0] ^ b[1] ^ b[2] ^ b[4]
    p1 = 1 - (b[1] ^ b[3] ^ b[4] ^ b[5])
    return frame_id | p0 << 6 | p1 << 7


def tied(ldf, f):
    return any(f.name == t.name for e in ldf.get_event_triggered_frames() for t in e.frames)


def stated_variants(path):
    """{node: whether its product_id states a variant}, from ldfparser's own parse tree."""
    from lark import Lark
    grammar = os.path.join(os.path.dirname(ldfparser.__file__), 'grammars', 'ldf.lark')
    with open(grammar, encoding='utf-8') as g, open(path, encoding='utf-8') as src:
        tree = Lark(g.read(), parser='lalr').parse(src.read())
    out = {}
    for nd in tree.find_data('node_definition'):
        name = str(nd.children[0].children[0])
        for prod in nd.find_data('node_definition_product_id'):
            out[name] = len(prod.children) > 2
    return out


def frame_name(f):
    return f.name


def dump(ldf, variants):
    out = []
    out.append(f'header protocol={ldf.get_protocol_version()} language={ldf.get_language_version()} '
               f'speed_bps={ldf.baudrate} channel={dash(unesc(ldf.channel))}')
    m = ldf.master
    out.append(f'master {m.name} time_base_ms={fmt_num(m.timebase * 1000)} jitter_ms={fmt_num(m.jitter * 1000)}')
    out.append('slaves ' + ','.join(s.name for s in ldf.slaves))
    for s in sorted(ldf.slaves, key=lambda s: s.name):
        if ldf.get_language_version() < ldfparser.lin.LIN_VERSION_2_0:
            break  # LIN 1.x has no Node_attributes; ldfparser invents defaulted slaves
        p = s.product_id
        variant = p.variant if p and variants.get(s.name) else '-'
        prod = f'0x{p.supplier_id:04X},0x{p.function_id:04X},{variant}' if p else '-'
        frames = []
        for key, f in s.configurable_frames.items():
            # LIN 2.0 keys a configurable frame by its message id, 2.1 by position
            if ldf.get_language_version() < ldfparser.lin.LIN_VERSION_2_1:
                frames.append(f'{f.name}=0x{key:04X}')
            else:
                frames.append(f.name)
        cnad = f'0x{s.configured_nad:02X}' if s.configured_nad is not None else '-'
        inad = f'0x{s.initial_nad:02X}' if s.initial_nad is not None else '-'
        out.append(f'node {s.name} protocol={s.lin_protocol} configured_nad={cnad} initial_nad={inad} '
                   f'product={prod} response_error={s.response_error.name if s.response_error else "-"} '
                   f'fault_state={",".join(x.name for x in s.fault_state_signals)} '
                   f'p2_min_ms={fmt_num(s.p2_min * 1000)} st_min_ms={fmt_num(s.st_min * 1000)} '
                   f'n_as_ms={fmt_num(s.n_as_timeout * 1000)} n_cr_ms={fmt_num(s.n_cr_timeout * 1000)} '
                   f'frames={",".join(frames)}')
    sigs = list(ldf.signals) + list(ldf.get_diagnostic_signals())
    for s in sorted(sigs, key=lambda s: s.name):
        init = '{' + ','.join(str(b) for b in s.init_value) + '}' if s.is_array() else str(s.init_value)
        pub = s.publisher.name if s.publisher else '-'
        subs = ','.join(x.name for x in s.subscribers)
        enc = s.encoding_type.name if s.encoding_type else '-'
        out.append(f'signal {s.name} width={s.width} init={init} publisher={pub} subscribers={subs} encoding={enc}')
    for e in sorted(ldf.get_signal_encoding_types(), key=lambda e: e.name):
        for c in e.get_converters():
            if isinstance(c, LogicalValue):
                out.append(f'encoding {e.name} logical value={c.phy_value} text={unesc(c.info) or ""}')
            elif isinstance(c, PhysicalValue):
                out.append(f'encoding {e.name} physical min={c.phy_min} max={c.phy_max} scale={fmt_num(c.scale)} '
                           f'offset={fmt_num(c.offset)} unit={unesc(c.unit) or ""}')
            elif isinstance(c, BCDValue):
                out.append(f'encoding {e.name} bcd')
            elif isinstance(c, ASCIIValue):
                out.append(f'encoding {e.name} ascii')
    frames = [(f.frame_id, 'frame', f) for f in ldf.get_unconditional_frames()]
    frames += [(f.frame_id, 'diag-frame', f) for f in ldf.get_diagnostic_frames()]
    for fid, kind, f in sorted(frames, key=lambda t: t[0]):
        if kind == 'frame':
            pub = f.publisher.name
            cs = checksum_for(ldf, f)
        else:
            pub = ldf.master.name if fid == 0x3C else '-'
            cs = 'classic'
        out.append(f'{kind} {f.name} id=0x{fid:02X} publisher={pub} len={f.length} checksum={cs}')
        for off, s in f.signal_map:
            out.append(f'frame-signal {f.name} {s.name} offset={off} width={s.width}')
        out.append(f'template {f.name} {template(ldf, f).hex().upper()}')
    for e in ldf.get_event_triggered_frames():
        table = e.collision_resolving_schedule_table.name if e.collision_resolving_schedule_table else '-'
        models = {checksum_for(ldf, f) for f in e.frames}
        cs = models.pop() if len(models) == 1 else '-'
        out.append(f'event {e.name} id=0x{e.frame_id:02X} table={table} '
                   f'frames={",".join(f.name for f in e.frames)} checksum={cs}')
    for s in ldf.get_sporadic_frames():
        out.append(f'sporadic {s.name} frames={",".join(f.name for f in s.frames)}')
    for t in ldf.get_schedule_tables():
        for i, entry in enumerate(t.schedule):
            if isinstance(entry, MasterRequestEntry):
                what = 'diagnostic MasterReq'
            elif isinstance(entry, SlaveResponseEntry):
                what = 'diagnostic SlaveResp'
            elif isinstance(entry, LinFrameEntry):
                f = entry.frame
                if isinstance(f, ldfparser.frame.LinEventTriggeredFrame):
                    what = f'event_triggered {f.name}'
                elif isinstance(f, ldfparser.frame.LinSporadicFrame):
                    what = f'sporadic {f.name}'
                else:
                    what = f'frame {f.name}'
            else:
                # a configuration command: its class name less "Entry", in the LDF's spelling
                name = type(entry).__name__[:-len('Entry')]
                what = 'command ' + {'AssignNad': 'AssignNAD', 'ConditionalChangeNad': 'ConditionalChangeNAD'}.get(name, name)
            out.append(f'schedule {t.name} {i} {what} delay_ms={fmt_num(entry.delay * 1000)}')
    return out


def with_pid(ldf, f, data):
    data = bytearray(data)
    if isinstance(f, LinUnconditionalFrame) and tied(ldf, f):
        data[0] = pid(f.frame_id)
    return bytes(data)


def template(ldf, f):
    return with_pid(ldf, f, f.encode_raw({}))


# --- sample encodes and decodes ---------------------------------------------------------------

def rules(s):
    return s.encoding_type.get_converters() if s.encoding_type else []


def samples(s):
    """(request text, ldfparser value) pairs for one signal: each encoding rule, raw limits."""
    out = []
    n = s.width // 8
    if s.is_array():
        out.append((f'bytes:{bytes(range(1, n + 1)).hex().upper()}', ('raw', list(range(1, n + 1)))))
        for c in rules(s):
            if isinstance(c, ASCIIValue):
                text = ('ABCDEFGH' * 2)[:n]
                out.append((f'text:{text}', ('list', c.encode(text, s))))
                out.append((f'text:{text[:-1]}', ('list', c.encode(text[:-1], s))))  # one short
            if isinstance(c, BCDValue):
                digits = '9876543210'[:n]
                shorter = int(digits[1:] or '0')  # fewer digits than the array holds
                out.append((f'text:{digits}', ('list', c.encode(int(digits), s))))
                out.append((f'raw:{shorter}', ('list', c.encode(shorter, s))))
        return out
    top = (1 << s.width) - 1
    for raw in sorted({0, top // 2, top}):
        out.append((f'raw:{raw}', ('raw', raw)))
    out.append((f'raw:{top + 1}', ('raw', top + 1)))
    for c in rules(s):
        if isinstance(c, LogicalValue) and c.info:
            out.append((f'text:{esc(unesc(c.info))}', ('enc', c.info)))
        if isinstance(c, PhysicalValue):
            for raw in sorted({c.phy_min, (c.phy_min + c.phy_max) // 2, c.phy_max}):
                phys = raw * c.scale + c.offset
                out.append((f'phys:{fmt_num(phys)}', ('enc', float(fmt_num(phys)))))
    if any(isinstance(c, PhysicalValue) for c in rules(s)):
        out.append(('phys:1e9', ('enc', 1e9)))
    if any(isinstance(c, LogicalValue) for c in rules(s)):
        out.append(('text:no such value', ('enc', 'no such value')))
    return out


def encode(ldf, f, values):
    """ldfparser's frame bytes for {signal: (how, value)}, or None where it refuses."""
    raw = {}
    for name, (how, v) in values.items():
        s = f._get_signal(name)
        if how in ('raw', 'list'):
            raw[name] = v
        else:
            try:
                raw[name] = s.encoding_type.encode(v, s)
            except ValueError:
                return None
    try:
        return with_pid(ldf, f, f.encode_raw(raw))
    except Exception:  # bitstruct refuses a value its field cannot hold
        return None


def decode_text(ldf, f, data):
    parts = []
    for name, v in f.decode_raw(bytearray(data)).items():
        s = f._get_signal(name)
        if s.is_array():
            text = ''
            for c in rules(s):
                if isinstance(c, ASCIIValue) and all(b < 0x80 for b in v):
                    text = c.decode(v, s)
                    break
                if isinstance(c, BCDValue) and all(b <= 9 for b in v):
                    text = str(c.decode(v, s)).zfill(len(v))
                    break
            part = f'{name}=bytes:{bytes(v).hex().upper()}'
            parts.append(part + (f' text:{text}' if text else ''))
            continue
        part = f'{name}=raw:{v}'
        for c in rules(s):
            if isinstance(c, (BCDValue, ASCIIValue)):
                continue
            try:
                got = c.decode(v, s)
            except ValueError:
                continue
            if isinstance(c, PhysicalValue):
                part += f' phys:{fmt_num(got)}' + (f' unit:{unesc(c.unit)}' if c.unit else '')
            elif c.info:
                part += f' text:{unesc(got)}'
            break
        parts.append(part)
    return ' '.join(parts)


def requests(ldf):
    """The request lines for ldf_dump.v and ldfparser's answer to each."""
    reqs, answers = [], []

    def ask(f, values):
        line = f'encode|{f.name}|' + '|'.join(f'{n}={t}' for n, (t, _) in values.items())
        got = encode(ldf, f, {n: v for n, (_, v) in values.items()})
        reqs.append(line)
        answers.append(f'{line} -> {got.hex().upper() if got is not None else "error"}')
        if got is not None:
            reqs.append(f'decode|{f.name}|{got.hex().upper()}')
            answers.append(f'decode {f.name} {got.hex().upper()} -> {decode_text(ldf, f, got)}')

    for f in sorted(ldf.get_unconditional_frames(), key=lambda f: f.frame_id):
        t = template(ldf, f).hex().upper()
        reqs.append(f'decode|{f.name}|{t}')
        answers.append(f'decode {f.name} {t} -> {decode_text(ldf, f, bytes.fromhex(t))}')
        per = {}
        for _, s in f.signal_map:
            per[s.name] = samples(s)
            for sample in per[s.name]:
                ask(f, {s.name: sample})
        # every signal at once, each at a sample it can take
        together = {name: ss[min(1, len(ss) - 1)] for name, ss in per.items()}
        ask(f, together)
    return reqs, answers


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ldf')
    ap.add_argument('--print', action='store_true', help="print ldfparser's lines and stop")
    a = ap.parse_args()

    ldf = ldfparser.parse_ldf(a.ldf, pad_with_zero=False)
    ours = dump(ldf, stated_variants(a.ldf))
    reqs, answers = requests(ldf)
    ours += answers
    if a.print:
        print('\n'.join(ours))
        return
    v = os.environ.get('V', 'v')
    run = subprocess.run([v, '-enable-globals', 'run', os.path.join(REPO, 'sut', 'ldf_dump.v'),
                          os.path.abspath(a.ldf)], input='\n'.join(reqs) + '\n', text=True,
                         capture_output=True, cwd=REPO)
    if run.returncode != 0:
        sys.exit(f'ldf_dump.v failed ({run.returncode}):\n{run.stderr}')
    theirs = [line for line in run.stdout.splitlines() if not line.startswith('note ')]
    diff = list(difflib.unified_diff(ours, theirs, 'ldfparser', 'lindb', lineterm=''))
    if diff:
        print('\n'.join(diff))
        sys.exit(1)
    print(f'agree: {len(ours)} lines ({len(answers)} encode/decode answers)')


if __name__ == '__main__':
    main()
