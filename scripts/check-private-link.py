#!/usr/bin/env python3
"""Read-only IPv4/VLAN qualification on raw Linux; root/device-binding privileges required."""
import argparse
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import time


def ip_json(*arguments):
    result = subprocess.run(['ip', '-j', *arguments], capture_output=True, text=True,
                            timeout=5, check=False)
    if result.returncode:
        raise ValueError(f'ip {" ".join(arguments)}: {result.stderr.strip()}')
    return json.loads(result.stdout)


def validate_direct_route(routes, interface, node_ip):
    if len(routes) != 1:
        raise ValueError('Private route is missing or ambiguous')
    route = routes[0]
    if (route.get('dev') != interface or route.get('from', route.get('prefsrc')) != node_ip
            or route.get('gateway') or route.get('type', 'unicast') != 'unicast'):
        raise ValueError('Bastion route must use the selected interface/source directly, without a gateway')
    return route


def validate_path(links, addresses, routes, interface, node_ip, vid):
    if len(links) != 1 or links[0].get('ifname') != interface:
        raise ValueError('Selected private interface is missing or ambiguous')
    link = links[0]
    if 'UP' not in link.get('flags', []) or link.get('operstate') != 'UP':
        raise ValueError('Selected private interface is not operationally UP')
    info = link.get('linkinfo', {})
    if info.get('info_kind') != 'vlan' or info.get('info_data', {}).get('id') != vid:
        raise ValueError('Selected private interface is not the expected VLAN ID')
    matching = [item for item in addresses if item.get('ifname') == interface]
    if len(matching) != 1 or not any(
            item.get('family') == 'inet' and item.get('local') == node_ip
            for item in matching[0].get('addr_info', [])):
        raise ValueError('Expected node IPv4 address is absent from the selected interface')
    route = validate_direct_route(routes, interface, node_ip)
    return {'interface': interface, 'nodeIPv4': node_ip, 'vid': vid, 'route': route}


def check_path(args):
    return validate_path(ip_json('-d', 'link', 'show', 'dev', args.interface),
                         ip_json('address', 'show', 'dev', args.interface),
                         ip_json('route', 'get', args.bastion_ip, 'from', args.node_ip),
                         args.interface, args.node_ip, args.vid)


def validate_neighbor(neighbors, bastion_ip, interface):
    rows = [row for row in neighbors if row.get('dst') == bastion_ip
            and row.get('dev') == interface]
    usable = {'REACHABLE', 'STALE', 'DELAY', 'PROBE', 'PERMANENT'}
    if (len(rows) != 1 or not usable.intersection(rows[0].get('state', []))
            or not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', rows[0].get('lladdr', ''))):
        raise ValueError(f'Private ARP unresolved or unusable: {neighbors}')
    return rows[0]


def check_arp(args):
    # iproute2 can omit "dev" when the query is already filtered by device.
    # Retain it in the returned records so validation checks the actual interface.
    return validate_neighbor(ip_json('neighbor', 'show', 'to', args.bastion_ip),
                             args.bastion_ip, args.interface)


def dns_name(packet, offset):
    labels, seen, end = [], set(), None
    while True:
        if offset in seen or offset >= len(packet):
            raise ValueError('DNS name is truncated or has a compression loop')
        seen.add(offset)
        length = packet[offset]
        if length & 0xc0 == 0xc0:
            if offset + 1 >= len(packet):
                raise ValueError('DNS pointer is truncated')
            end = offset + 2 if end is None else end
            offset = ((length & 0x3f) << 8) | packet[offset + 1]
            continue
        if length & 0xc0:
            raise ValueError('DNS label encoding is invalid')
        offset += 1
        if length == 0:
            return '.'.join(labels).lower(), offset if end is None else end
        if offset + length > len(packet):
            raise ValueError('DNS label is truncated')
        labels.append(packet[offset:offset + length].decode('ascii'))
        if sum(map(len, labels)) + len(labels) > 255:
            raise ValueError('DNS name is too long')
        offset += length


def validate_dns(packet, transaction, hostname, expected_ip):
    if len(packet) < 12:
        raise ValueError('DNS response is truncated')
    identity, flags, questions, answers, _, _ = struct.unpack_from('!6H', packet)
    if identity != transaction or flags & 0xfa4f != 0x8000 or questions != 1:
        raise ValueError('DNS transaction, response flags, rcode or question count is invalid')
    name, offset = dns_name(packet, 12)
    if name != hostname or packet[offset:offset + 4] != struct.pack('!HH', 1, 1):
        raise ValueError('DNS response question does not match the requested A record')
    offset += 4
    found = []
    for _ in range(answers):
        name, offset = dns_name(packet, offset)
        if offset + 10 > len(packet):
            raise ValueError('DNS answer header is truncated')
        kind, record_class, _, length = struct.unpack_from('!HHIH', packet, offset)
        offset += 10
        if offset + length > len(packet):
            raise ValueError('DNS answer data is truncated')
        if kind == 1 and record_class == 1 and name == hostname:
            if length != 4:
                raise ValueError('DNS IPv4 record length is invalid')
            found.append(socket.inet_ntoa(packet[offset:offset + length]))
        offset += length
    if not found or set(found) != {expected_ip}:
        raise ValueError(f'DNS direct A answer must contain only {expected_ip}; received {found}')
    return {'hostname': hostname, 'addresses': found}


def bind_interface(stream, interface):
    if sys.platform != 'linux' or not hasattr(socket, 'SO_BINDTODEVICE'):
        raise OSError('Linux SO_BINDTODEVICE is required; no unbound probe is permitted')
    try:
        stream.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode('ascii') + b'\0')
    except PermissionError as error:
        raise PermissionError('Cannot bind probe to the reviewed interface; run with sudo/root '
                              'or the required Linux network capabilities') from error


def check_flow_route(args, stream, protocol, port):
    source, source_port = stream.getsockname()
    if source != args.node_ip or not 1 <= source_port <= 65535:
        raise ValueError('Probe socket has an unexpected source address or no allocated source port')
    try:
        routes = ip_json('route', 'get', args.bastion_ip, 'from', source,
                         'oif', args.interface, 'ipproto', protocol,
                         'sport', str(source_port), 'dport', str(port))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise ValueError('Exact-flow route lookup failed; iproute2 must support '
                         f'oif/ipproto/sport/dport selectors (no fallback): {error}') from error
    return validate_direct_route(routes, args.interface, args.node_ip)


def udp_query(args, port, request):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
        bind_interface(stream, args.interface)
        stream.settimeout(args.timeout)
        stream.bind((args.node_ip, 0))
        check_flow_route(args, stream, 'udp', port)
        stream.connect((args.bastion_ip, port))
        stream.send(request)
        return stream.recv(4096)


def check_dns(args):
    transaction = secrets.randbelow(65536)
    name = b''.join(bytes([len(label)]) + label.encode('ascii')
                    for label in args.mirror_hostname.split('.')) + b'\0'
    query = struct.pack('!6H', transaction, 0x100, 1, 0, 0, 0) + name + struct.pack('!HH', 1, 1)
    return validate_dns(udp_query(args, 53, query), transaction, args.mirror_hostname, args.bastion_ip)


def validate_ntp(packet, originate):
    if len(packet) < 48:
        raise ValueError('NTP response is truncated')
    leap, version, mode = packet[0] >> 6, (packet[0] >> 3) & 7, packet[0] & 7
    if leap == 3 or version not in (3, 4) or mode != 4 or not 1 <= packet[1] <= 15:
        raise ValueError('NTP server is unsynchronized or its version/mode/stratum is invalid')
    if packet[24:32] != originate:
        raise ValueError('NTP response does not match this request')
    if packet[32:40] == bytes(8) or packet[40:48] == bytes(8):
        raise ValueError('NTP receive/transmit timestamp is missing')
    if packet[32:40] > packet[40:48]:
        raise ValueError('NTP transmit timestamp precedes receipt of the request')
    return {'version': version, 'stratum': packet[1], 'leap': leap,
            'receiveTimestamp': packet[32:40].hex(), 'transmitTimestamp': packet[40:48].hex()}


def check_ntp(args):
    # Fresh transmit timestamp also serves as the response's originate nonce.
    seconds = int(time.time()) + 2208988800
    originate = struct.pack('!I', seconds & 0xffffffff) + secrets.token_bytes(4)
    request = bytes([0x23]) + bytes(39) + originate
    return validate_ntp(udp_query(args, 123, request), originate)


def check_tls(args):
    context = ssl.create_default_context(cafile=str(args.ca_file))
    deadline = time.monotonic() + args.timeout

    def remaining():
        value = deadline - time.monotonic()
        if value <= 0:
            raise TimeoutError('Mirror TLS/HTTP probe deadline exceeded')
        return value

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as raw:
        bind_interface(raw, args.interface)
        raw.settimeout(remaining())
        raw.bind((args.node_ip, 0))
        check_flow_route(args, raw, 'tcp', args.mirror_port)
        raw.settimeout(remaining())
        raw.connect((args.bastion_ip, args.mirror_port))
        raw.settimeout(remaining())
        with context.wrap_socket(raw, server_hostname=args.mirror_hostname) as stream:
            if stream.getsockname()[0] != args.node_ip:
                raise ValueError('Mirror probe used an unexpected source address')
            stream.settimeout(remaining())
            stream.sendall(f'GET /v2/ HTTP/1.1\r\nHost: {args.mirror_hostname}:{args.mirror_port}\r\nConnection: close\r\n\r\n'.encode())
            status = b''
            while b'\r\n' not in status and len(status) < 256:
                stream.settimeout(remaining())
                chunk = stream.recv(256 - len(status))
                if not chunk:
                    break
                status += chunk
            first = status.split(b'\r\n', 1)[0]
            match = re.fullmatch(rb'HTTP/1\.[01] (200|401)(?: [\x20-\x7e]*)?', first)
            if b'\r\n' not in status or not match:
                raise ValueError(f'Mirror returned an unexpected HTTP status line: {first!r}')
            return {'httpStatus': int(match[1]), 'tlsVersion': stream.version(),
                    'proof': 'CA-verified registry service only; authenticated image pull untested'}


def evidence_path(value):
    path = Path(value).expanduser().absolute()
    resolved = path.resolve()
    forbidden_paths = [Path('/mnt/c/homelab')]
    # The standalone script is copied to raw hosts. Only treat its grandparent
    # as the checkout when the repository markers are actually present.
    checkout = Path(__file__).resolve().parents[1]
    if (checkout / 'ansible/up.sh').is_file() and (checkout / 'install/release-manifest.json').is_file():
        forbidden_paths.append(checkout)
    for forbidden in forbidden_paths:
        if resolved == forbidden or forbidden in resolved.parents:
            raise ValueError('Evidence must be outside the repository and Homelab')
    parent = path.parent.stat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or parent.st_mode & 0o077:
        raise ValueError('Evidence parent must be an existing owner-only directory owned by this account')
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('Existing evidence must be an owner-only regular file owned by this account')
    return path


def write_evidence(path, result):
    descriptor, temporary = tempfile.mkstemp(prefix='.private-link-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(result, stream, indent=2)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('interface', 'node-ip', 'bastion-ip', 'mirror-hostname', 'ca-file'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--vid', type=int, required=True)
    parser.add_argument('--mirror-port', type=int, default=8443)
    parser.add_argument('--timeout', type=float, default=3)
    parser.add_argument('--evidence', help='Optional JSON path in an existing private external directory')
    args = parser.parse_args(argv)
    try:
        for value in (args.node_ip, args.bastion_ip):
            address = ipaddress.IPv4Address(value)
            if address.is_unspecified or address.is_multicast or address.is_loopback:
                raise ValueError('Node and bastion must be unicast, non-loopback IPv4 addresses')
        if args.node_ip == args.bastion_ip:
            raise ValueError('Node and bastion IPv4 addresses must differ')
        if (not re.fullmatch(r'[a-zA-Z0-9_.:-]{1,15}', args.interface)
                or args.interface.startswith('-') or not 1 <= args.vid <= 4094
                or not 1 <= args.mirror_port <= 65535 or not 0.1 <= args.timeout <= 30):
            raise ValueError('Invalid interface, VID, port or timeout')
        args.mirror_hostname = args.mirror_hostname.lower().rstrip('.')
        if len(args.mirror_hostname) > 253 or not all(
                re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label)
                for label in args.mirror_hostname.split('.')):
            raise ValueError('Mirror hostname must be a valid ASCII DNS name')
        args.ca_file = Path(args.ca_file)
        if not args.ca_file.is_file():
            raise ValueError('Mirror CA file does not exist')
        target = evidence_path(args.evidence) if args.evidence else None
    except (OSError, ValueError) as error:
        parser.error(str(error))

    result = {'recordedAt': datetime.now(timezone.utc).isoformat(), 'status': 'FAIL',
              'scope': 'Raw provider OS private IPv4/VLAN path; no install or enforcement proof',
              'inputs': {key: str(value) for key, value in vars(args).items() if key != 'evidence'},
              'checks': {}}

    def record(name, operation):
        try:
            detail = operation()
            result['checks'][name] = {'status': 'PASS', 'detail': detail}
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            result['checks'][name] = {'status': 'FAIL', 'error': f'{type(error).__name__}: {error}'}
        print(f"{result['checks'][name]['status']} {name}: "
              f"{result['checks'][name].get('error', 'verified')}")
        return result['checks'][name]['status'] == 'PASS'

    if record('interface/source/VID', lambda: check_path(args)):
        # The bounded probes cause ordinary neighbor resolution; no interface or
        # neighbor configuration is modified, including on a failed probe.
        record('mirrorTLS', lambda: check_tls(args))
        record('DNS', lambda: check_dns(args))
        record('NTP', lambda: check_ntp(args))
        record('ARP', lambda: check_arp(args))
        record('pathAfterProbes', lambda: check_path(args))
    if all(check['status'] == 'PASS' for check in result['checks'].values()):
        result['status'] = 'PASS'
    if target:
        write_evidence(target, result)
    print(f"{result['status']} private link; authenticated image pull and enforcement are untested.")
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
