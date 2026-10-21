#!/usr/bin/env python3
"""Render the helper's cloud-init user data from the mirror bootstrap template."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import sys

import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / 'ansible/bootstrap/mirror-registry.yaml.j2'


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ssh-user', required=True, help='login user of the helper image')
    parser.add_argument('--vlan-vid', default='auto',
                        help="VLAN tag on the wire, or auto (default) to adopt the provider's private VLAN on the helper")
    parser.add_argument('--mirror-registry-url', required=True, help='versioned HTTPS mirror-registry archive URL')
    parser.add_argument('--mirror-registry-sha256', required=True, help='SHA-256 of that archive')
    parser.add_argument('--vlan-parent-interface', default='auto', help="helper NIC that carries the VLAN (default: auto)")
    # Used only with an explicit --vlan-vid. Defaults match ansible/group_vars/all.yml.
    parser.add_argument('--helper-vlan-ip', default='192.168.66.10')
    parser.add_argument('--vlan-cidr', default='192.168.66.0/24')
    parser.add_argument('--registry-dns-name', default='mirror.rig.local')
    parser.add_argument('--mirror-root', default='/opt/mirror')
    parser.add_argument('--init-user', default='init')
    return parser.parse_args(argv)


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


def main(argv=None):
    try:
        sys.stdout.write(render(parameters(parse_args(argv))))
    except ValueError as error:
        print(f'render-helper-bootstrap: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
