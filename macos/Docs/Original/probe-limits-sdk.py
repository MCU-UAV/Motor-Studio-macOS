"""Run with Windows Python. Uses SDK encoding only; never opens a serial port.
Example: probe-limits-sdk.py --dll UnitreeMotorSDK.dll --output limits-vectors.json
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--dll', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
path = Path(args.dll).resolve()
expected = '8330abd072b79b0b83e795894e4ff5b4558289be36319b6d69aaa0fa2dd06488'
if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
    raise RuntimeError('SDK hash differs from inspected binary')
dll = c.CDLL(str(path))
new = dll.NewUnitreeMotor
new.argtypes = [c.c_char_p, c.c_char_p, c.c_int, c.c_int]
new.restype = c.c_void_p
pack = dll.PackTxAndGetMainData
pack.argtypes = [c.c_void_p, c.c_void_p, c.c_int]
pack.restype = c.c_int
delete = dll.DeleteUnitreeMotor
delete.argtypes = [c.c_void_p]
delete.restype = None
motor = new(b'COM_DOES_NOT_EXIST', b'N1215-288', 0, 6000000)
if not motor:
    raise RuntimeError('SDK object creation failed')
rows = []
try:
    for name in ['Set_Control_Data_Out', 'Set_Control_Data_Rotor']:
        control = getattr(dll, name)
        control.argtypes = [c.c_void_p, c.c_int, c.c_char_p, c.c_int] + [c.c_double] * 5
        control.restype = c.c_int
        for index in range(5):
            for value in [-1e300, -1e8, -1, 0, 1, 1e8, 1e300]:
                values = [0.0] * 5
                values[index] = value
                status = control(motor, 0, b'Foc', 1, *values)
                out = c.create_string_buffer(128)
                count = pack(motor, out, len(out))
                if count != 20:
                    raise RuntimeError(f'Unexpected frame size: {count}')
                rows.append(dict(side=name, values=values, rc=status, hex=out.raw[:count].hex()))
finally:
    delete(motor)
Path(args.output).write_text(json.dumps(rows, indent=2) + '\n', encoding='utf-8')
print(f'Generated {len(rows)} SDK saturation vectors without serial I/O.')
