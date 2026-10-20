#!/usr/bin/env python3
"""Render every Mermaid block in repository Markdown so a syntax error fails the check.

Needs Node.js 22+ (npx). The pinned mermaid-cli and its headless Chrome are
fetched on first use; set PUPPETEER_EXECUTABLE_PATH to reuse an installed
Chrome or Chromium instead. Not part of `make lint`; CI runs it separately.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

MERMAID_CLI = '@mermaid-js/mermaid-cli@12.0.0'
root = Path(__file__).resolve().parent.parent
names = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', '*.md'],
    cwd=root,
).decode().split('\0')
blocks = []
for name in sorted(n for n in names if n and (root / n).is_file()):
    text = (root / name).read_text()
    for match in re.finditer(r'^```mermaid\n(.*?)^```', text, flags=re.M | re.S):
        blocks.append((f'{name}:{text.count(chr(10), 0, match.start()) + 1}', match.group(1)))
if not blocks:
    sys.exit('No Mermaid blocks found')
if not shutil.which('npx'):
    sys.exit('ERROR: npx is required (install Node.js 22+)')

errors = []
with tempfile.TemporaryDirectory() as temp:
    config = Path(temp) / 'puppeteer.json'
    browser = {'args': ['--no-sandbox']}
    if os.environ.get('PUPPETEER_EXECUTABLE_PATH'):
        browser['executablePath'] = os.environ['PUPPETEER_EXECUTABLE_PATH']
    config.write_text(json.dumps(browser))
    for index, (where, source) in enumerate(blocks):
        diagram = Path(temp) / f'{index}.mmd'
        diagram.write_text(source)
        result = subprocess.run(
            ['npx', '--yes', MERMAID_CLI, '--quiet', '--puppeteerConfigFile', str(config),
             '--input', str(diagram), '--output', str(diagram.with_suffix('.svg'))],
            capture_output=True, text=True)
        if result.returncode:
            errors.append(f'{where}: {(result.stderr or result.stdout).strip()}')
        else:
            print(f'ok  {where}')
if errors:
    print('\n\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'All {len(blocks)} Mermaid diagrams render')
