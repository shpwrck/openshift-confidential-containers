#!/usr/bin/env python3
"""Check local file and heading links in repository Markdown, including READMEs."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

root = Path(__file__).resolve().parent.parent
errors = []
names = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', '*.md'],
    cwd=root,
).decode().split('\0')
paths = sorted({root / name for name in names if name and (root / name).is_file()})


def anchors(path):
    body = re.sub(r'```.*?```', '', path.read_text(), flags=re.S)
    found = set(re.findall(r'<a\s+[^>]*(?:id|name)=[\'"]([^\'"]+)', body))
    counts = {}
    for heading in re.findall(r'^#{1,6}\s+(.+?)\s*#*$', body, flags=re.M):
        slug = re.sub(r'[^\w\-\s]', '', heading.lower()).replace(' ', '-')
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        found.add(f'{slug}-{count}' if count else slug)
    return found


for path in paths:
    body = re.sub(r'```.*?```', '', path.read_text(), flags=re.S)
    for dest in re.findall(r'\]\(([^\s)]+)(?:\s+[^)]*)?\)', body):
        link = urlsplit(dest.strip('<>'))
        if link.scheme or link.netloc or link.path.startswith('/'):
            continue
        target = path.parent / unquote(link.path) if link.path else path
        if not target.exists():
            errors.append(f'{path.relative_to(root)}: missing {link.path}')
        elif link.fragment and target.suffix == '.md' and unquote(link.fragment) not in anchors(target):
            errors.append(f'{path.relative_to(root)}: missing heading {dest}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Local file and heading links resolve in {len(paths)} Markdown documents')
