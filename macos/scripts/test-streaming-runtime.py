#!/usr/bin/env python3
"""Compile actual stream/record/table code with a delayed multi-motor simulator."""
import argparse
import pathlib
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--swift', default='swift')
parser.add_argument('--swiftc', default='swiftc')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
build = pathlib.Path(subprocess.check_output([args.swift, 'build', '--show-bin-path'], cwd=root, text=True).strip())
with tempfile.TemporaryDirectory(prefix='motor-stream-') as folder:
    binary = pathlib.Path(folder) / 'stream-tests'
    files = ['AcquisitionEngine', 'Sample', 'ChartMetric', 'RecordingStore', 'IndexedRecording', 'MotorTable']
    cmd = [args.swiftc, '-swift-version', '5', '-parse-as-library', '-O', str(root / 'scripts/test-streaming-runtime.swift')]
    cmd += [str(root / f'Sources/MotorStudio/{name}.swift') for name in files]
    cmd += ['-I', str(build / 'Modules'), '-I', str(build / 'CSerial.build')]
    cmd += list(map(str, sorted((build / 'MotorCore.build').glob('*.swift.o'))))
    cmd += [str(build / 'CSerial.build/Serial.c.o'), '-o', str(binary)]
    if platform.system() == 'Darwin': cmd += ['-framework', 'IOKit']
    subprocess.run(cmd, check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
