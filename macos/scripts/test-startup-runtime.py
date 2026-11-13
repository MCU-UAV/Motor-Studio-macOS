#!/usr/bin/env python3
"""Compile the real acquisition engine with a latched firmware simulator; no physical I/O."""
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
# swift test first builds MotorCore with @testable access. No SwiftUI stubs are involved.
build = pathlib.Path(subprocess.check_output([args.swift, 'build', '--show-bin-path'], cwd=root, text=True).strip())
source = (root / 'Tests/MotorCoreTests/StartupTests.swift').read_text()
start = source.index('private final class LatchedSerial:')
end = source.index('\nfinal class StartupTests:', start)
driver = 'import Foundation\n@testable import MotorCore\n' + source[start:end].replace('private final class LatchedSerial:', 'final class LatchedSerial:', 1)
with tempfile.TemporaryDirectory(prefix='motor-startup-') as folder:
    simulated = pathlib.Path(folder) / 'Simulated.swift'
    simulated.write_text(driver)
    binary = pathlib.Path(folder) / 'startup-tests'
    files = ['AcquisitionEngine', 'Sample', 'ChartMetric', 'RecordingStore', 'IndexedRecording']
    command = [args.swiftc, '-swift-version', '5', '-parse-as-library', '-O', str(simulated), str(root / 'scripts/test-startup-runtime.swift')]
    command += [str(root / f'Sources/MotorStudio/{name}.swift') for name in files]
    command += ['-I', str(build / 'Modules'), '-I', str(build / 'CSerial.build')]
    command += list(map(str, sorted((build / 'MotorCore.build').glob('*.swift.o'))))
    command += [str(build / 'CSerial.build/Serial.c.o'), '-o', str(binary)]
    if platform.system() == 'Darwin': command += ['-framework', 'IOKit']
    subprocess.run(command, check=True)
    subprocess.run([str(binary)], check=True)
