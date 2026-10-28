#!/usr/bin/env python3
"""Run the offline test modules side by side, one process per module.

One after another the modules take about eight minutes, mostly in the ones that
run ansible-playbook. This runs as many at once as there are CPUs, slowest first,
and prints the full output of every module that failed.

  python3 scripts/run-tests.py                  every tests/test_*.py module
  python3 scripts/run-tests.py test_order_rig   only the named modules (or tests/test_order_rig.py)
  JOBS=1 python3 scripts/run-tests.py           one at a time
"""
from concurrent.futures import ThreadPoolExecutor, as_completed
import os
from pathlib import Path
import re
import subprocess
import sys
import time

TESTS = Path(__file__).resolve().parent.parent / "tests"
# The slowest modules, slowest first, so they start at once; a module not listed
# counts as quick. The first two take more than half of the sequential time.
SLOWEST = ("test_install_private_link", "test_bootstrap", "test_bastion_network", "test_discovery",
           "test_boot_publication", "test_worker_safety")


def count(number, noun):
    return f"{number} {noun}{'' if number == 1 else 's'}"


def run(module):
    started = time.monotonic()
    result = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", str(TESTS), "-p", f"{module}.py", "-v"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    ran = re.search(r"^Ran (\d+) tests?", result.stdout, re.M)
    return module, result.returncode, int(ran.group(1)) if ran else 0, time.monotonic() - started, result.stdout


def main(names):
    modules = [Path(name).stem for name in names] or sorted(p.stem for p in TESTS.glob("test_*.py"))
    missing = [name for name in modules if not (TESTS / f"{name}.py").is_file()]
    if missing:
        print(f"ERROR: no test module {', '.join(missing)} in {TESTS}", file=sys.stderr)
        return 2
    modules.sort(key=lambda name: SLOWEST.index(name) if name in SLOWEST else len(SLOWEST))
    jobs = min(len(modules), max(1, int(os.environ.get("JOBS") or os.cpu_count() or 1)))
    print(f"Running {count(len(modules), 'test module')}, {jobs} at a time.", flush=True)
    started = time.monotonic()
    failed, total = [], 0
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for future in as_completed([pool.submit(run, module) for module in modules]):
            module, code, ran, seconds, output = future.result()
            total += ran
            print(f"{'ok  ' if code == 0 else 'FAIL'}  {module}  {count(ran, 'test')}, {seconds:.0f}s", flush=True)
            if code != 0 or ran == 0:
                failed.append((module, output))
    for module, output in failed:
        print(f"\n===== {module} =====\n{output}")
    print(f"\nRan {count(total, 'test')} in {count(len(modules), 'module')} in {time.monotonic() - started:.0f}s, "
          f"{jobs} at a time.")
    if failed:
        print(f"FAILED: {', '.join(module for module, _ in failed)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
