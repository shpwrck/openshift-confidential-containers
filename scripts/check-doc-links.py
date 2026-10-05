#!/usr/bin/env python3
"""Check local file destinations in maintained Markdown; ignore URL/anchor targets."""
from pathlib import Path
import re
import sys
from urllib.parse import unquote
root = Path(__file__).resolve().parent.parent
errors = []
for path in [root / 'README.md', *sorted((root / 'docs').rglob('*.md'))]:
    body = re.sub(r'```.*?```', '', path.read_text(), flags=re.S)
    for dest in re.findall(r'\]\(([^\s)]+)(?:\s+[^)]*)?\)', body):
        dest = dest.strip('<>').split('#')[0].split('?')[0]
        if not dest or re.match(r'^[a-zA-Z][\w+.-]*:', dest) or dest.startswith('/'):
            continue
        if not (path.parent / unquote(dest)).exists():
            errors.append(f'{path.relative_to(root)}: missing {dest}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Local Markdown file links resolve')
