"""Bounded local protocol/path controls; no provider or infrastructure access."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, call, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('private_link', ROOT / 'scripts/check-private-link.py')
link = importlib.util.module_from_spec(spec)
spec.loader.exec_module(link)


@contextlib.contextmanager
def loopback_binding():
    """Keep real protocol fixtures portable; bind the real device when permitted."""
    supported = False
    interface = 'lo'
    if link.sys.platform == 'linux' and shutil.which('ip'):
        # WSL mirrored networking can route loopback through loopback0, not lo.
        route = subprocess.run(['ip', '-j', 'route', 'get', '127.0.0.1'], capture_output=True,
                               text=True, check=True, timeout=5)
        interface = json.loads(route.stdout)[0]['dev']
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            link.bind_interface(probe, interface)
            supported = True
    except OSError:
        pass
    # These fixtures test real UDP/TLS on loopback, which need not have a direct
    # Linux private-LAN route (WSL routes it through a gateway). Exact-flow route
    # selection and rejection are tested separately with controlled ip output.
    with patch.object(link, 'check_flow_route'):
        if supported:
            yield interface
        else:
            # macOS and unprivileged Linux cannot use SO_BINDTODEVICE.
            with patch.object(link, 'bind_interface'):
                yield interface


class ProtocolTests(unittest.TestCase):
    def dns_packet(self, address='192.168.66.10', **overrides):
        name = b'\x06mirror\x03rig\x05local\0'
        header = struct.pack('!6H', overrides.get('transaction', 123),
                             overrides.get('flags', 0x8180), 1, 1, 0, 0)
        question = name + struct.pack('!HH', 1, 1)
        answer = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 60, 4) + socket.inet_aton(address)
        return header + question + answer

    def test_dns_requires_matching_transaction_question_and_direct_a_answer(self):
        good = self.dns_packet()
        self.assertEqual(link.validate_dns(good, 123, 'mirror.rig.local', '192.168.66.10')['addresses'],
                         ['192.168.66.10'])
        for packet in (self.dns_packet('192.168.66.99'), self.dns_packet(transaction=124),
                       self.dns_packet(flags=0x8380), self.dns_packet(flags=0x8183),
                       self.dns_packet(flags=0x81c0),
                       good.replace(b'mirror', b'forged'), good[:-1], good[:8]):
            with self.subTest(packet=packet), self.assertRaises(ValueError):
                link.validate_dns(packet, 123, 'mirror.rig.local', '192.168.66.10')

    def test_dns_compression_loop_and_out_of_bounds_are_rejected(self):
        for packet in (b'\xc0\x00', b'\xc0\xff', b'\xc0', b'\x40', b'\x04abc'):
            with self.subTest(packet=packet), self.assertRaises(ValueError):
                link.dns_name(packet, 0)

    def ntp_packet(self):
        packet = bytearray(48)
        packet[0], packet[1] = 0x24, 3
        packet[24:32] = b'nonce123'
        packet[32:40] = b'time1234'
        packet[40:48] = b'time2345'
        return packet

    def test_ntp_requires_synchronized_server_and_fresh_request_identity(self):
        good = self.ntp_packet()
        self.assertEqual(link.validate_ntp(good, b'nonce123')['stratum'], 3)
        for index, value in ((0, 0xe4), (0, 0x23), (0, 0x14), (1, 0), (1, 16), (24, 0)):
            bad = good.copy()
            bad[index] = value
            with self.subTest(index=index, value=value), self.assertRaises(ValueError):
                link.validate_ntp(bad, b'nonce123')
        for bad in (good[:47], good[:40] + bytes(8), good[:32] + bytes(8) + good[40:]):
            with self.assertRaises(ValueError):
                link.validate_ntp(bad, b'nonce123')
        with self.assertRaises(ValueError):
            link.validate_ntp(good[:32] + good[40:48] + good[32:40], b'nonce123')

    def test_udp_queries_use_bound_source_and_validate_live_response(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(('127.0.0.1', 0))
            server.settimeout(2)
            peers = []

            def answer():
                request, peer = server.recvfrom(4096)
                peers.append(peer)
                server.sendto(self.dns_packet(transaction=struct.unpack_from('!H', request)[0]), peer)

            thread = threading.Thread(target=answer, daemon=True)
            thread.start()
            args = SimpleNamespace(node_ip='127.0.0.1', bastion_ip='127.0.0.1', timeout=1, interface='lo')
            with loopback_binding() as args.interface:
                result = link.udp_query(args, server.getsockname()[1], struct.pack('!H', 123))
            thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertEqual(peers[0][0], '127.0.0.1')
            link.validate_dns(result, 123, 'mirror.rig.local', '192.168.66.10')

    def test_udp_timeout_is_bounded(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as silent:
            silent.bind(('127.0.0.1', 0))
            args = SimpleNamespace(node_ip='127.0.0.1', bastion_ip='127.0.0.1', timeout=0.1, interface='lo')
            with loopback_binding() as args.interface, self.assertRaises(TimeoutError):
                link.udp_query(args, silent.getsockname()[1], b'query')


class DeviceBindingTests(unittest.TestCase):
    def setUp(self):
        self.args = SimpleNamespace(node_ip='192.168.66.11', bastion_ip='192.168.66.10',
                                    interface='eno2.2032', timeout=1, mirror_port=8443,
                                    ca_file=Path('/fixture/ca.pem'), mirror_hostname='mirror.test')

    def exercise(self, protocol, stream, route=None):
        stream.getsockname.return_value = ('192.168.66.11', 41000)
        route = route if route is not None else {'dev': 'eno2.2032', 'from': '192.168.66.11'}
        with patch.object(link.socket, 'socket') as factory, \
                patch.object(link.ssl, 'create_default_context') as tls, \
                patch.object(link, 'ip_json', return_value=[route]) as lookup:
            factory.return_value.__enter__.return_value = stream
            if protocol == 'UDP':
                link.udp_query(self.args, 53, b'query')
            else:
                # Stop after connect so the assertion concerns actual socket setup,
                # before TLS owns the socket; protocol behavior has real fixtures.
                tls.return_value.wrap_socket.side_effect = RuntimeError('socket setup complete')
                with self.assertRaisesRegex(RuntimeError, 'socket setup complete'):
                    link.check_tls(self.args)
            return lookup

    def test_every_probe_binds_reviewed_device_before_source_and_connect(self):
        for protocol in ('UDP', 'TLS'):
            with self.subTest(protocol=protocol), patch.object(link.sys, 'platform', 'linux'), \
                    patch.object(link.socket, 'SO_BINDTODEVICE', 25, create=True):
                stream = MagicMock()
                lookup = self.exercise(protocol, stream)
                device = call.setsockopt(socket.SOL_SOCKET, 25, b'eno2.2032\0')
                source = call.bind(('192.168.66.11', 0))
                connect = call.connect(('192.168.66.10', 53 if protocol == 'UDP' else 8443))
                self.assertLess(stream.mock_calls.index(device), stream.mock_calls.index(source))
                self.assertLess(stream.mock_calls.index(source), stream.mock_calls.index(connect))
                lookup.assert_called_once_with('route', 'get', '192.168.66.10', 'from', '192.168.66.11',
                                               'oif', 'eno2.2032', 'ipproto', 'udp' if protocol == 'UDP' else 'tcp',
                                               'sport', '41000', 'dport', '53' if protocol == 'UDP' else '8443')

    def test_service_policy_gateway_route_prevents_connection_and_transmission(self):
        direct = {'dev': 'eno2.2032', 'from': '192.168.66.11'}
        # The generic route remains direct; only this socket's service flow is
        # redirected by policy. Device binding alone cannot reject this gateway.
        link.validate_direct_route([direct], self.args.interface, self.args.node_ip)
        for protocol in ('UDP', 'TLS'):
            with self.subTest(protocol=protocol), patch.object(link.sys, 'platform', 'linux'), \
                    patch.object(link.socket, 'SO_BINDTODEVICE', 25, create=True):
                stream = MagicMock()
                with self.assertRaisesRegex(ValueError, 'without a gateway'):
                    self.exercise(protocol, stream, dict(direct, gateway='192.168.66.1'))
                for method in ('connect', 'send', 'sendall', 'recv'):
                    getattr(stream, method).assert_not_called()

    def test_unsupported_flow_selectors_fail_without_fallback(self):
        stream = MagicMock()
        stream.getsockname.return_value = ('192.168.66.11', 41000)
        with patch.object(link.subprocess, 'run', return_value=subprocess.CompletedProcess(
                ['ip'], 1, '', 'Error: argument "ipproto" is wrong')) as command, \
                self.assertRaisesRegex(ValueError, 'iproute2 must support.*no fallback'):
            link.check_flow_route(self.args, stream, 'tcp', 8443)
        command.assert_called_once()
        self.assertEqual(command.call_args.args[0], [
            'ip', '-j', 'route', 'get', '192.168.66.10', 'from', '192.168.66.11',
            'oif', 'eno2.2032', 'ipproto', 'tcp', 'sport', '41000', 'dport', '8443'])

    def test_device_binding_failure_prevents_connect_and_all_transmission(self):
        for protocol in ('UDP', 'TLS'):
            for error in (PermissionError('denied'), OSError('device unavailable')):
                with self.subTest(protocol=protocol, error=error), patch.object(link.sys, 'platform', 'linux'), \
                        patch.object(link.socket, 'SO_BINDTODEVICE', 25, create=True):
                    stream = MagicMock()
                    stream.setsockopt.side_effect = error
                    with self.assertRaises(OSError):
                        self.exercise(protocol, stream)
                    for method in ('bind', 'connect', 'send', 'sendall', 'recv'):
                        getattr(stream, method).assert_not_called()

    def test_unsupported_platform_has_no_unbound_fallback(self):
        stream = MagicMock()
        with patch.object(link.sys, 'platform', 'darwin'), self.assertRaises(OSError):
            link.bind_interface(stream, 'eno2.2032')
        stream.setsockopt.assert_not_called()


class PathTests(unittest.TestCase):
    def setUp(self):
        self.links = [{'ifname': 'eno2.2032', 'flags': ['UP'], 'operstate': 'UP',
                       'linkinfo': {'info_kind': 'vlan', 'info_data': {'id': 2032}}}]
        self.addresses = [{'ifname': 'eno2.2032', 'addr_info': [
            {'family': 'inet', 'local': '192.168.66.11'}]}]
        self.routes = [{'dev': 'eno2.2032', 'from': '192.168.66.11'}]

    def validate(self):
        return link.validate_path(self.links, self.addresses, self.routes,
                                  'eno2.2032', '192.168.66.11', 2032)

    def test_valid_private_vlan_route_passes(self):
        self.assertEqual(self.validate()['vid'], 2032)

    def test_wrong_source_interface_gateway_or_route_kind_fails(self):
        for key, value in (('dev', 'eno1'), ('from', '10.0.0.1'), ('gateway', '192.168.66.1'),
                           ('type', 'local')):
            with self.subTest(key=key), patch.dict(self.routes[0], {key: value}), self.assertRaises(ValueError):
                self.validate()

    def test_wrong_vid_down_link_or_missing_node_address_fails(self):
        with patch.dict(self.links[0]['linkinfo']['info_data'], {'id': 2026}), self.assertRaises(ValueError):
            self.validate()
        with patch.dict(self.links[0], {'operstate': 'DOWN'}), self.assertRaises(ValueError):
            self.validate()
        self.addresses[0]['addr_info'] = []
        with self.assertRaises(ValueError):
            self.validate()

    def test_failed_or_wrong_peer_arp_cannot_pass(self):
        good = {'dst': '192.168.66.10', 'dev': 'eno2.2032', 'state': ['REACHABLE'],
                'lladdr': '90:5a:08:31:0d:6f'}
        link.validate_neighbor([good], '192.168.66.10', 'eno2.2032')
        for key, value in (('state', ['FAILED']), ('state', ['INCOMPLETE']), ('dev', 'eno1'),
                           ('dst', '192.168.66.99'), ('lladdr', '')):
            with self.subTest(key=key), patch.dict(good, {key: value}), self.assertRaises(ValueError):
                link.validate_neighbor([good], '192.168.66.10', 'eno2.2032')

    def test_neighbor_query_retains_device_identity_from_iproute2(self):
        args = SimpleNamespace(bastion_ip='192.168.66.10', interface='eno2.2032')

        def iproute2(command, **kwargs):
            row = {'dst': args.bastion_ip, 'state': ['REACHABLE'],
                   'lladdr': '90:5a:08:31:0d:6f'}
            # Actual iproute2 output omits dev when the command uses a dev filter.
            if 'dev' not in command:
                row['dev'] = args.interface
            return subprocess.CompletedProcess(command, 0, json.dumps([row]), '')

        with patch.object(link.subprocess, 'run', side_effect=iproute2) as run:
            self.assertEqual(link.check_arp(args)['dev'], args.interface)
        self.assertEqual(run.call_args.args[0], ['ip', '-j', 'neighbor', 'show', 'to', args.bastion_ip])
        for row in ({'dst': args.bastion_ip, 'state': ['REACHABLE'], 'lladdr': '90:5a:08:31:0d:6f'},
                    {'dst': args.bastion_ip, 'state': ['REACHABLE'], 'lladdr': '90:5a:08:31:0d:6f',
                     'dev': 'eno1'}):
            with self.subTest(row=row), patch.object(link, 'ip_json', return_value=[row]), \
                    self.assertRaises(ValueError):
                link.check_arp(args)

    def test_wrong_path_prevents_all_service_probes_and_retains_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            ca = base / 'ca.pem'
            ca.touch()
            evidence = base / 'result.json'
            argv = ['--interface', 'eno2.2032', '--node-ip', '192.168.66.11', '--vid', '2032',
                    '--bastion-ip', '192.168.66.10', '--mirror-hostname', 'mirror.rig.local',
                    '--ca-file', str(ca), '--evidence', str(evidence)]
            with patch.object(link, 'check_path', side_effect=ValueError('wrong private source')), \
                    patch.object(link, 'check_tls') as tls, patch.object(link, 'check_dns') as dns, \
                    patch.object(link, 'check_ntp') as ntp, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(link.main(argv), 1)
            tls.assert_not_called()
            dns.assert_not_called()
            ntp.assert_not_called()
            result = json.loads(evidence.read_text())
            self.assertIn('wrong private source', result['checks']['interface/source/VID']['error'])
            self.assertEqual(evidence.stat().st_mode & 0o777, 0o600)

    def test_evidence_refuses_repo_public_directory_and_symlink(self):
        with self.assertRaises(ValueError):
            link.evidence_path(ROOT / 'result.json')
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            target = base / 'target'
            target.touch(mode=0o600)
            alias = base / 'alias'
            alias.symlink_to(target)
            with self.assertRaises(ValueError):
                link.evidence_path(alias)
            base.chmod(0o755)
            with self.assertRaises(ValueError):
                link.evidence_path(base / 'result.json')

    def test_standalone_copy_does_not_treat_filesystem_root_as_checkout(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(link, '__file__', '/tmp/check-private-link.py'):
            target = Path(temp) / 'result.json'
            self.assertEqual(link.evidence_path(target), target.absolute())


@unittest.skipUnless(shutil.which('openssl'), 'local TLS fixture requires openssl')
class TLSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.temp.name)
        cls.cert, cls.key = cls.base / 'ca.pem', cls.base / 'key.pem'
        cls.other_ca = cls.base / 'other-ca.pem'
        for cert, key in ((cls.cert, cls.key), (cls.other_ca, cls.base / 'other-key.pem')):
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-subj', '/CN=mirror.test', '-addext', 'subjectAltName=DNS:mirror.test',
                            '-keyout', str(key), '-out', str(cert)],
                           check=True, capture_output=True, timeout=15)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def probe(self, status=401, hostname='mirror.test', ca=None):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.cert, self.key)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            listener.settimeout(2)

            def serve():
                try:
                    raw, _ = listener.accept()
                    with raw, context.wrap_socket(raw, server_side=True) as stream:
                        stream.settimeout(2)
                        stream.recv(4096)
                        stream.sendall(f'HTTP/1.1 {status} Fixture\r\nContent-Length: 0\r\n\r\n'.encode())
                except (OSError, ssl.SSLError):
                    pass  # Negative TLS controls intentionally reject the handshake.

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            args = SimpleNamespace(node_ip='127.0.0.1', bastion_ip='127.0.0.1', timeout=1, interface='lo',
                                   mirror_hostname=hostname, ca_file=ca or self.cert,
                                   mirror_port=listener.getsockname()[1])
            try:
                with loopback_binding() as args.interface:
                    return link.check_tls(args)
            finally:
                thread.join(3)
                self.assertFalse(thread.is_alive())

    def test_authenticated_registry_challenge_only_proves_tls_service(self):
        result = self.probe(401)
        self.assertEqual(result['httpStatus'], 401)
        self.assertIn('authenticated image pull untested', result['proof'])

    def test_wrong_hostname_untrusted_ca_and_http_failure_are_rejected(self):
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.probe(hostname='wrong.test')
        # A different CA cannot authenticate the fixture's certificate.
        with self.assertRaises(ssl.SSLError):
            self.probe(ca=self.other_ca)
        with self.assertRaises(ValueError):
            self.probe(status=503)


if __name__ == '__main__':
    unittest.main()
