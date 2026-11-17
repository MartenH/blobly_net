"""The rest bus: the database feeds the simulated nodes, the real ECU under test is on the bus, a
test drives both (docs/rest_bus.md, README.md)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drawio import Diagram

d = Diagram('rest-bus', 'Rest-bus simulation from the database', 980, 430)
# the database
d.box(20, 120, 150, 70, 'DBC or ARXML\nthe network\'s database', 'yellow', bold=True, fs=12)
d.text(20, 196, 150, 56, 'ids, cycle times, start\nvalues, E2E, senders —\nnothing restated', fs=10)
# Blobly Net with the simulated nodes
d.box(220, 20, 380, 320, 'Blobly Net — the rest of the bus', 'grey', bold=True, valign='top', fs=12)
d.text(236, 44, 350, 18, 'simulate: [BodyECU, ChassisECU, BatteryECU]', fs=10, color='#333333')
for i, (name, what) in enumerate([('BodyECU', 'BodyStatus every 200 ms'),
                                  ('ChassisECU', 'WheelSpeeds 20 ms, BrakeStatus 50 ms'),
                                  ('BatteryECU', 'BatteryStatus every 500 ms')]):
    y = 72 + i * 58
    d.box(240, y, 120, 44, name, 'blue', fs=12)
    d.text(372, y + 2, 215, 18, what, fs=10)
d.box(240, 250, 340, 70, 'each frame as the database says: cycle and event timing,\n'
      'start values, multiplexing, CAN-FD, declared E2E;\nfrom the project: UDS answers, NM where configured',
      'plain', fs=10)
d.line([(170, 155), (220, 155)])
# the bus
d.bar(640, 20, 14, 320, 'orange')
d.text(612, 344, 70, 40, 'CAN / CAN-FD', fs=10, align='center', bold=True)
for y in (94, 152, 210):
    d.line([(360, y + 6), (640, y + 6)])
# the ECU under test
d.box(700, 120, 160, 70, 'ECU under test\nreal hardware on the bench', 'green', bold=True, fs=12)
d.line([(654, 155), (700, 155)], both=True)
d.text(700, 196, 270, 56, 'any adapter: SocketCAN, PCAN, Kvaser,\nVector, CANsub — or a virtual bus\nwith a stand-in, for CI', fs=10)
# the test
d.box(220, 370, 380, 44, 'your test — Python, Lua or the GUI: set a signal, inject a fault,\nexpect what the ECU under test answers', 'orange', fs=11)
d.line([(410, 370), (410, 340)])
d.text(700, 262, 270, 42, 'the trace tells them apart:\nTX-S the rest bus, RX what we did not send', fs=10)
d.write(os.path.join(sys.argv[1], 'rest-bus.drawio.svg'))
