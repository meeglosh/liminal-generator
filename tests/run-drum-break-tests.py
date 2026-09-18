#!/usr/bin/env python3
"""Run the standalone macOS DSP regression harness using Xcode's Swift compiler."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = sorted(str(p) for p in (root / 'LiminalGenerator/Audio').glob('*.swift')
                 if p.name != 'AudioEngineController.swift')
with tempfile.TemporaryDirectory(prefix='liminal-drum-tests-') as scratch:
    binary = str(Path(scratch) / 'tests')
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(Path(scratch) / 'modules'),
                    *sources, str(root / 'LiminalGenerator/Resources/Loops/LoopManifest.swift'),
                    str(root / 'tests/DrumBreakTests.swift'), '-o', binary], check=True)
    subprocess.run([binary], check=True)
