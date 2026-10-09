#!/usr/bin/env python3
"""Render exact initdata or a proof Pod without contacting Kubernetes."""
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from workload import initdata, render
import yaml

try:
    rung = sys.argv[1]
    if os.environ.get("EMIT_INITDATA") == "1":
        sys.stdout.buffer.write(initdata(os.environ, rung))
    else:
        print(yaml.safe_dump(render(os.environ, rung), sort_keys=False), end="")
except (ValueError, KeyError, OSError) as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    sys.exit(2)
