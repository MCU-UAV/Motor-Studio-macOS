"""Offline fixture generator; never opens a serial port or writes configuration.
Run with Windows Python: probe-sdk.py --dll PATH --output sdk-vectors.json
"""
import argparse
import ctypes as c
import json
import random
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--dll', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
dll = c.CDLL(str(Path(args.dll).resolve()))

def function(name, types, result=c.c_int):
    f = getattr(dll, name)
    f.argtypes = types
    f.restype = result
    return f

new = function('NewUnitreeMotor', [c.c_char_p, c.c_char_p, c.c_int, c.c_int], c.c_void_p)
pack = function('PackTxAndGetMainData', [c.c_void_p, c.c_void_p, c.c_int])
control = function('Set_Control_Data_Out', [c.c_void_p, c.c_int, c.c_char_p, c.c_int] + [c.c_double] * 5)
delete = function('DeleteUnitreeMotor', [c.c_void_p], None)
motor = new(b'COM_DOES_NOT_EXIST', b'N1215-288', 0, 6000000)
if not motor:
    raise RuntimeError('SDK object creation failed')
cases = [
    (0, 'Stop', 0, 0, 0, 0, 0, 0),
    (0, 'Stop', 1, 0, 0, 0, 0, 0),
    (3, 'Foc', 1, .1, .5, .25, 1, .1),
    (14, 'Foc', 1, -.2, -.75, -.5, 2, .2),
    (0, 'Foc', 1, 0, 0, .000001, 0, 0),
]
rng = random.Random(288)
for i in range(64):
    cases.append((i % 15, 'Foc', 1, rng.uniform(-.5, .5), rng.uniform(-2, 2),
                  rng.uniform(-3, 3), rng.uniform(0, 5), rng.uniform(0, .5)))
vectors = []
try:
    for mid, mode, otp, tor, spd, pos, kp, kd in cases:
        result = control(motor, mid, mode.encode(), otp, tor, spd, pos, kp, kd)
        if result != 0:
            raise RuntimeError(f'SDK rejected input: {result}')
        out = c.create_string_buffer(1024)
        size = pack(motor, out, len(out))
        if size != 20:
            raise RuntimeError(f'Unexpected frame size: {size}')
        vectors.append(dict(id=mid, mode=mode, timeout=otp, torque=tor, speed=spd,
                            position=pos, kp=kp, kd=kd, hex=out.raw[:size].hex()))
finally:
    delete(motor)
Path(args.output).write_text(json.dumps(vectors, indent=2) + '\n', encoding='utf-8')
print(f'Generated {len(vectors)} SDK vectors without opening a serial port.')
