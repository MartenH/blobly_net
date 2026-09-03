#!/usr/bin/env python3
"""arxml_oracle.py — cantools' reading of an ARXML, in the line-per-fact form
`cmd/arxml2dbc --dump` prints, so the two can be diffed by `diff` alone.

    python3 sut/arxml_oracle.py dbc/example.arxml [--cluster Body] > /tmp/oracle.txt
    v -enable-globals -path "@vlib|@vmodules|modules" run cmd/arxml2dbc/ dbc/example.arxml --dump > /tmp/ours.txt
    diff /tmp/oracle.txt <(grep -v '^e2e-layout\|^e2e-header' /tmp/ours.txt)

An independent implementation is the point (see README.md): agreement between a V reader and a
V writer proves only that they agree with each other. What is deliberately NOT compared, because
the two model different things:

  - `e2e-layout` / `e2e-header` lines (CRC and counter bytes, or a fixed-header profile's
    offset): cantools keeps the profile and data ids only, so the offsets are ours alone to
    prove — arxml_test.v pins them against the fixture.
  - signal min/max: cantools takes the LINEAR compu scale's raw domain, this reader the declared
    DATA-CONSTR (physical) when there is one; both are legitimate AUTOSAR and they differ.
  - descriptions: cantools folds every language, this reader takes the first L-2.
  - receivers of a frame WITHOUT signals (an N-PDU, say): cantools records receivers per
    signal, so it has nowhere to put those; this reader records them per frame. On
    dbc/example.arxml that is the one remaining diff line (DiagReq).

Needs cantools (requirements.txt).
"""
import argparse
import sys

import cantools


def fmt_num(x):
    if x is None:
        return '1'
    if float(x) == int(float(x)):
        return str(int(float(x)))
    return repr(float(x))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('arxml')
    ap.add_argument('--cluster', default='')
    a = ap.parse_args()

    db = cantools.database.load_file(a.arxml, strict=False)
    buses = {b.name: b for b in db.buses}
    if a.cluster:
        if a.cluster not in buses:
            sys.exit(f'no cluster {a.cluster}; have {sorted(buses)}')
        bus = buses[a.cluster]
    elif len(buses) == 1:
        bus = next(iter(buses.values()))
    else:
        sys.exit(f'{len(buses)} clusters ({sorted(buses)}): name one with --cluster')

    msgs = [m for m in db.messages if (m.bus_name or bus.name) == bus.name]
    print(f'cluster {bus.name} baudrate={bus.baudrate or 0} fd_baudrate={bus.fd_baudrate or 0}')
    nodes = set()
    for m in msgs:
        nodes.update(m.senders)
        for s in m.signals:
            nodes.update(s.receivers)
    print('nodes ' + ','.join(sorted(nodes)))
    for m in sorted(msgs, key=lambda m: (m.frame_id, m.is_extended_frame)):
        receivers = set()
        for s in m.signals:
            receivers.update(s.receivers)
        print(f'message {m.name} id=0x{m.frame_id:X} ext={str(m.is_extended_frame).lower()} '
              f'len={m.length} fd={str(bool(m.is_fd)).lower()} cycle_ms={m.cycle_time or 0} '
              f'senders={",".join(sorted(m.senders))} receivers={",".join(sorted(receivers))}')
        for s in sorted(m.signals, key=lambda s: s.name):
            order = 'little' if s.byte_order == 'little_endian' else 'big'
            choices = ';'.join(f'{int(k)}={v}' for k, v in sorted(s.choices.items())) if s.choices else ''
            print(f'signal {m.name}.{s.name} start={s.start} len={s.length} order={order} '
                  f'signed={str(s.is_signed).lower()} factor={fmt_num(s.scale)} '
                  f'offset={fmt_num(s.offset)} unit={s.unit or ""} choices={choices}')
        ar = m.autosar
        if ar is not None and ar.e2e is not None:
            e = ar.e2e
            # cantools models the profile and data ids, not the offsets (see the docstring)
            print(f'e2e {m.name} profile={e.category} data_id={e.data_ids[0] if e.data_ids else 0}')
        if ar is not None and ar.secoc is not None:
            print(f'secoc {m.name} data_id={ar.secoc.data_id} payload_len={ar.secoc.payload_length}')


if __name__ == '__main__':
    main()
