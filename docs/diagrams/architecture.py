"""One engine, every face: the GUI, Python, Lua, C and the CLI tools all drive the same GUI-free
engine in blobly/, which reaches every bus (README.md)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drawio import Diagram

d = Diagram('architecture', 'One engine, every face', 980, 420)
faces = [('GUI', 'Dear ImGui + ImPlot'), ('Python', 'pip install blobly'),
         ('Lua', 'test runner, CI'), ('C ABI', 'libblobly, bb.h'), ('CLI tools', 'flash, restbus, ...')]
for i, (name, sub) in enumerate(faces):
    x = 20 + i * 192
    d.box(x, 20, 172, 50, f'{name}\n{sub}', 'orange', fs=11)
    d.line([(x + 86, 70), (x + 86, 110)])
d.box(20, 110, 940, 150, 'the engine — blobly/, GUI-free and unit-tested', 'grey', bold=True,
      valign='top', fs=12)
eng = [('rest bus and\nsimulated ECUs', 'sim, replay'), ('diagnostics', 'ISO-TP, UDS, DoIP,\nflash'),
       ('databases', 'DBC, ARXML, LDF,\nJ1939, NM'), ('recordings', 'candump, MF4,\nstreamed replay'),
       ('trace', 'whose frame, health,\nload, E2E')]
for i, (name, sub) in enumerate(eng):
    x = 36 + i * 186
    d.box(x, 140, 170, 100, f'{name}\n\n{sub}', 'blue', fs=11)
d.line([(490, 260), (490, 300)], both=True)
d.box(20, 300, 940, 100, 'the buses it reaches', 'grey', bold=True, valign='top', fs=12)
buses = [('CAN / CAN-FD', 'SocketCAN, PCAN,\nKvaser, Vector, CANsub'), ('no hardware', 'in-process and\nUDP buses'),
         ('CAN bridge', 'WSL or a LAN\nhost\'s interfaces'), ('Ethernet', 'DoIP, SOME/IP'),
         ('LIN', 'serial, in-process')]
for i, (name, sub) in enumerate(buses):
    x = 36 + i * 186
    d.box(x, 326, 170, 60, f'{name}\n{sub}', 'green', fs=11)
d.write(os.path.join(sys.argv[1], 'architecture.drawio.svg'))
