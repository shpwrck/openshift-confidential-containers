#!/usr/bin/env python3
"""Render the helper's mirror bootstrap from its cloud-init template.

By default the output is a root shell script to run on the helper over SSH. On
Cherry Servers, a server ordered with user data gets neither the order's SSH key
nor its private VLAN, so the helper is ordered without user data and the
bootstrap is run afterwards. --cloud-config prints cloud-init user data instead,
for providers that keep their own setup when user data is given.
"""
import argparse
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import sys

import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / 'ansible/bootstrap/mirror-registry.yaml.j2'
MANIFEST = Path(os.environ.get('RELEASE_MANIFEST') or ROOT / 'install/release-manifest.json')


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cloud-config', action='store_true',
                        help='print cloud-init user data instead of a shell script')
    parser.add_argument('--ssh-user', default='root',
                        help='login user that cloud-init configures (only with --cloud-config; default root)')
    parser.add_argument('--vlan-vid', default='auto',
                        help="VLAN tag on the wire, or auto (default) to adopt the provider's private VLAN on the helper")
    parser.add_argument('--mirror-registry-url', help="versioned HTTPS mirror-registry archive URL (default: the release manifest's tools.mirrorRegistry)")
    parser.add_argument('--mirror-registry-sha256', help='SHA-256 of that archive (default: from the release manifest)')
    parser.add_argument('--vlan-parent-interface', default='auto', help="helper NIC that carries the VLAN (default: auto)")
    # Used only with an explicit --vlan-vid. Defaults match ansible/group_vars/all.yml.
    parser.add_argument('--helper-vlan-ip', default='192.168.66.10')
    parser.add_argument('--vlan-cidr', default='192.168.66.0/24')
    parser.add_argument('--registry-dns-name', default='mirror.rig.local')
    parser.add_argument('--mirror-root', default='/opt/mirror')
    parser.add_argument('--init-user', default='init')
    args = parser.parse_args(argv)
    if (args.mirror_registry_url is None) != (args.mirror_registry_sha256 is None):
        parser.error('give --mirror-registry-url and --mirror-registry-sha256 together')
    if args.mirror_registry_url is None:
        pin = json.loads(MANIFEST.read_text())['tools']['mirrorRegistry']
        args.mirror_registry_url, args.mirror_registry_sha256 = pin['url'], pin['sha256']
    return args


def network_values(args):
    if args.vlan_vid == 'auto':
        return dict(vlan_vid='auto', bastion_vlan_ip='auto', vlan_prefix='auto', vlan_subnet='auto')
    if not re.fullmatch(r'[0-9]{1,4}', args.vlan_vid) or not 1 <= int(args.vlan_vid) <= 4094:
        raise ValueError('--vlan-vid must be auto or between 1 and 4094')
    network = ipaddress.ip_network(args.vlan_cidr, strict=True)
    if ipaddress.ip_address(args.helper_vlan_ip) not in network:
        raise ValueError(f'{args.helper_vlan_ip} is not in {network}')
    return dict(vlan_vid=int(args.vlan_vid), bastion_vlan_ip=args.helper_vlan_ip,
                vlan_prefix=network.prefixlen, vlan_subnet=str(network))


def parameters(args):
    if not args.mirror_registry_url.startswith('https://') or '/latest/' in args.mirror_registry_url:
        raise ValueError('--mirror-registry-url must be a versioned HTTPS URL, not a /latest/ one')
    if not re.fullmatch(r'[0-9a-fA-F]{64}', args.mirror_registry_sha256):
        raise ValueError('--mirror-registry-sha256 must be 64 hex characters')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]', args.registry_dns_name):
        raise ValueError('--registry-dns-name must be a DNS name')
    if not re.fullmatch(r'[A-Za-z0-9_.:-]+', args.vlan_parent_interface):
        raise ValueError('--vlan-parent-interface must be an interface name or auto')
    return dict(network_values(args), bastion_ssh_user=args.ssh_user,
                vlan_parent_interface=args.vlan_parent_interface, registry_dns_name=args.registry_dns_name,
                mirror_root=args.mirror_root, init_user=args.init_user,
                mirror_registry_url=args.mirror_registry_url, mirror_registry_sha256=args.mirror_registry_sha256)


def render(values):
    env = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
    env.filters['to_json'] = json.dumps
    text = env.from_string(TEMPLATE.read_text()).render(values)
    if not text.startswith('#cloud-config\n') or not isinstance(yaml.safe_load(text), dict):
        raise ValueError('rendered user data is not a cloud-config document')
    return text


def to_script(text):
    """Do what cloud-init would do with the rendered document, as one root shell script."""
    document = yaml.safe_load(text)
    # The user block and final message only mean something to cloud-init; the
    # script runs as the root login the provider already set up.
    unsupported = set(document) - {'user', 'packages', 'write_files', 'runcmd', 'final_message'}
    if unsupported:
        raise ValueError(f'cannot turn cloud-config keys into a script: {sorted(unsupported)}')
    lines = ['#!/bin/bash',
             '# Generated by scripts/render-helper-bootstrap.py; run as root on the helper.',
             'set -euo pipefail',
             '[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }',
             f"dnf -y install {shlex.join(document['packages'])}"]
    for item in document['write_files']:
        path, mode = item['path'], item.get('permissions', '0644')
        if not re.fullmatch(r'/[A-Za-z0-9._/-]+', path) or not re.fullmatch(r'0[0-7]{3}', mode):
            raise ValueError(f'unexpected write_files entry: {path}')
        encoded = base64.encodebytes(item['content'].encode()).decode()
        lines += [f'install -d -m 0755 {shlex.quote(str(Path(path).parent))}',
                  f"base64 -d > {shlex.quote(path)} <<'__END_OF_FILE__'", encoded.rstrip('\n'), '__END_OF_FILE__',
                  f'chmod {mode} {shlex.quote(path)}']
    for command in document['runcmd']:
        lines.append(shlex.join(command) if isinstance(command, list) else command)
    return '\n'.join(lines) + '\n'


def main(argv=None):
    try:
        args = parse_args(argv)
        text = render(parameters(args))
        sys.stdout.write(text if args.cloud_config else to_script(text))
    except ValueError as error:
        print(f'render-helper-bootstrap: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
