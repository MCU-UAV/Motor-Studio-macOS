#!/usr/bin/env python3
"""Compatibility entry point. macOS runs the real Observation/model runtime tests."""
import pathlib
import platform
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
if platform.system() == 'Darwin':
    subprocess.run(['bash', str(root / 'scripts/test-native-runtime.sh')], cwd=root, check=True)
else:
    print('The model now uses native Observation. Run model tests on macOS with scripts/test-native-runtime.sh.\nLinux protocol tests remain available through swift test.', file=sys.stderr)
    sys.exit(2)
