#!/usr/bin/env python3
"""Plan PXE publication cleanup without deleting installer sources or active paths."""
import argparse
import json
import os
import stat
import tempfile
from pathlib import Path
import sys

LEGACY_WEBROOT = '/opt/install/boot-artifacts'
SYSTEM_TREES = ('/etc', '/usr', '/bin', '/sbin', '/lib', '/lib64', '/boot', '/dev', '/proc', '/sys',
                '/run', '/root', '/var/lib', '/var/cache', '/var/log', '/var/spool', '/var/run', '/var/lock')
BROAD_DIRECTORIES = ('/', '/opt', '/var', '/var/www', '/srv', '/tmp', '/var/tmp', '/home', '/Users', '/mnt', '/media')
HOME_ROOTS = ('/home', '/Users')


def overlap(first, second):
    return first == second or first in second.parents or second in first.parents


def unsafe_publication_target(target):
    if target in {Path(path).resolve() for path in BROAD_DIRECTORIES} or target == Path.home().resolve():
        return True
    if target.parent in {Path(path).resolve() for path in HOME_ROOTS}:
        return True
    return any(target == Path(path).resolve() or Path(path).resolve() in target.parents for path in SYSTEM_TREES)


def read_sources(path):
    if not path.exists() and not path.is_symlink():
        return []
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('Publication metadata must be an owner-only regular file owned by the current account')
    value = json.loads(path.read_text())
    if (not isinstance(value, dict) or set(value) != {'version', 'sources'} or value['version'] != 1
            or not isinstance(value['sources'], list)
            or any(not isinstance(source, str) or not Path(source).is_absolute()
                   or any(ord(char) < 32 for char in source) for source in value['sources'])):
        raise ValueError('Invalid protected publication-source metadata')
    return value['sources']


def remember_sources(path, sources):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = path.parent.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('Publication metadata directory must be owner-only and owned by the current account')
    encoded = json.dumps({'version': 1, 'sources': sorted({str(Path(source).resolve()) for source in sources})}) + '\n'
    if path.exists() and path.read_text() == encoded:
        return False
    descriptor, temporary = tempfile.mkstemp(prefix='.publication-sources-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(encoded)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return True


def cleanup_plan(webroot, sources, mode, legacy=LEGACY_WEBROOT):
    if mode not in ('serve', 'stop'):
        raise ValueError('Publication mode must be serve or stop')
    for value in [webroot, legacy, *sources]:
        if not value or any(ord(char) < 32 for char in value):
            raise ValueError('Publication/source paths must be nonempty and contain no control characters')
    target = Path(webroot).resolve()
    protected = [Path(source).resolve() for source in sources]
    if unsafe_publication_target(target):
        raise ValueError('Public webroot must be a dedicated directory outside system trees and broad storage/home roots')
    if any(overlap(target, source) for source in protected):
        raise ValueError('Public webroot overlaps private installer source/assets; choose a separate publication directory')
    previous = Path(legacy).resolve()
    preserve_legacy = any(overlap(previous, source) for source in protected)
    if mode == 'serve' and overlap(previous, target):
        preserve_legacy = True
    # Validate through symlinks but remove named publication entries, never their
    # protected targets. Source trees are never recursively chmodded or removed.
    paths = [os.path.abspath(webroot)] if mode == 'stop' else []
    if not preserve_legacy and os.path.abspath(legacy) not in paths:
        paths.append(os.path.abspath(legacy))
    return {'remove': paths, 'preservedLegacy': preserve_legacy}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('serve', 'stop'), required=True)
    parser.add_argument('--webroot', required=True)
    parser.add_argument('--source', action='append', required=True)
    parser.add_argument('--output', choices=('json', 'paths'), default='json')
    parser.add_argument('--state-file', type=Path)
    parser.add_argument('--remember-sources', nargs='?', const='true', default='false', choices=('true', 'false'))
    args = parser.parse_args()
    try:
        args.remember_sources = args.remember_sources == 'true'
        sources = list(args.source)
        if args.state_file:
            sources.extend(read_sources(args.state_file))
            # Metadata is private input, never part of a served/deleted tree.
            sources.append(str(args.state_file.resolve()))
        if args.remember_sources and (args.mode != 'serve' or args.state_file is None):
            raise ValueError('Remembering sources requires serve mode and a protected state file')
        plan = cleanup_plan(args.webroot, sources, args.mode)
        plan['metadataChanged'] = remember_sources(args.state_file, sources) if args.remember_sources else False
    except (OSError, ValueError) as error:
        print(f'Unsafe boot publication paths: {error}', file=sys.stderr)
        return 1
    if args.output == 'paths':
        for path in plan['remove']:
            print(path)
    else:
        print(json.dumps(plan))
    return 0


if __name__ == '__main__':
    sys.exit(main())
