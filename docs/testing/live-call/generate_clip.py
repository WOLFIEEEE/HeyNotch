#!/usr/bin/env python3
"""Regenerate the non-private speech fixture using macOS's installed system voice."""
from pathlib import Path
import subprocess
import tempfile

PHRASE = "Call channel verification. Cobalt river forty two. The invoice is one hundred twenty seven dollars. Do not send it today."
ROOT = Path(__file__).resolve().parent

with tempfile.TemporaryDirectory(prefix="heynotch-call-fixture-") as directory:
    source = Path(directory) / "remote.aiff"
    subprocess.run(["say", "-v", "Samantha", "-r", "155", "-o", str(source), PHRASE], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(source), str(ROOT / "remote.wav")], check=True)
print("Generated local-only speech fixture:", ROOT / "remote.wav")
