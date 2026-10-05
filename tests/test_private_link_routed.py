"""Routed-path controls; local fixtures only, no provider or infrastructure calls."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

from test_private_link import link


class RoutedPathTests(unittest.TestCase):
    def setUp(self):
        self.args = SimpleNamespace(interface='eno1', node_ip='192.0.2.11',
                                    bastion_ip='198.51.100.10', gateway='192.0.2.1',
                                    prefix_length=24, expected_mac='02:00:00:00:00:11',
                                    network_mode='public-routed-lab', timeout=1, mirror_port=8443,
                                    ca_file=Path('/fixture/ca'), mirror_hostname='mirror.test')
        self.links = [{'ifname': 'eno1', 'flags': ['UP'], 'operstate': 'UP', 'link_type': 'ether',
                       'address': self.args.expected_mac}]
        self.addresses = [{'ifname': 'eno1', 'addr_info': [
            {'family': 'inet', 'local': self.args.node_ip, 'prefixlen': 24}]}]
        self.route = {'dev': 'eno1', 'from': self.args.node_ip, 'gateway': self.args.gateway}

    def validate(self, links=None, addresses=None, route=None):
        return link.validate_routed_path(links or self.links, addresses or self.addresses,
                                        [route or self.route], self.args.interface, self.args.node_ip,
                                        self.args.gateway, self.args.prefix_length, self.args.expected_mac)

    def test_public_route_requires_exact_source_device_gateway_and_physical_mac(self):
        self.assertEqual(self.validate()['gateway'], self.args.gateway)
        for key, value in [('dev', 'eno2'), ('from', '192.0.2.12'), ('gateway', '192.0.2.2'),
                           ('gateway', None), ('type', 'local')]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.validate(route=dict(self.route, **{key: value}))
        for key, value in [('address', '02:00:00:00:00:12'), ('operstate', 'DOWN'),
                           ('link_type', 'loopback'), ('linkinfo', {'info_kind': 'vlan'})]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.validate(links=[dict(self.links[0], **{key: value})])
        addresses = copy.deepcopy(self.addresses)
        addresses[0]['addr_info'][0]['prefixlen'] = 25
        with self.assertRaisesRegex(ValueError, 'address/prefix'):
            self.validate(addresses=addresses)

    def test_generic_path_checks_gateway_is_direct_and_neighbor_is_gateway_not_bastion(self):
        direct = {'dev': 'eno1', 'from': self.args.node_ip}
        with patch.object(link, 'ip_json', side_effect=[self.links, self.addresses, [self.route], [direct]]) as ip:
            self.assertEqual(link.check_path(self.args)['gateway'], self.args.gateway)
        self.assertEqual(ip.call_args.args, ('route', 'get', self.args.gateway, 'from', self.args.node_ip))
        neighbor = {'dst': self.args.gateway, 'dev': 'eno1', 'state': ['REACHABLE'],
                    'lladdr': '02:00:00:00:00:01'}
        with patch.object(link, 'ip_json', return_value=[neighbor]) as ip:
            self.assertEqual(link.check_arp(self.args)['dst'], self.args.gateway)
        ip.assert_called_once_with('neighbor', 'show', 'to', self.args.gateway)
        with patch.object(link, 'ip_json', side_effect=[self.links, self.addresses, [self.route], [self.route]]), \
                self.assertRaisesRegex(ValueError, 'without a gateway'):
            link.check_path(self.args)

    def test_wrong_flow_gateway_stops_udp_and_tls_before_connection(self):
        for kind in ('udp', 'tcp'):
            with self.subTest(kind=kind), patch.object(link, 'bind_interface') as bind, \
                    patch.object(link.socket, 'socket') as factory, \
                    patch.object(link.ssl, 'create_default_context'), \
                    patch.object(link, 'ip_json', return_value=[dict(self.route, gateway='192.0.2.2')]) as ip:
                stream = factory.return_value.__enter__.return_value
                stream.getsockname.return_value = (self.args.node_ip, 41000)
                with self.assertRaisesRegex(ValueError, 'exact reviewed gateway'):
                    if kind == 'udp':
                        link.udp_query(self.args, 53, b'query')
                    else:
                        link.check_tls(self.args)
                bind.assert_called_once_with(stream, 'eno1')
                self.assertEqual(ip.call_args.args, ('route', 'get', self.args.bastion_ip, 'from', self.args.node_ip,
                                                     'oif', 'eno1', 'ipproto', kind, 'sport', '41000',
                                                     'dport', '53' if kind == 'udp' else '8443'))
                for method in ('connect', 'send', 'sendall', 'recv'):
                    getattr(stream, method).assert_not_called()

    def test_successful_routed_flow_still_checks_actual_source_port(self):
        stream = MagicMock()
        stream.getsockname.return_value = (self.args.node_ip, 41000)
        with patch.object(link, 'ip_json', return_value=[self.route]):
            self.assertEqual(link.check_flow_route(self.args, stream, 'udp', 123), self.route)
        stream.getsockname.return_value = ('192.0.2.12', 41000)
        with patch.object(link, 'ip_json') as ip, self.assertRaises(ValueError):
            link.check_flow_route(self.args, stream, 'udp', 123)
        ip.assert_not_called()

    def argv(self, ca, evidence):
        return ['--network-mode', 'public-routed-lab', '--interface', 'eno1',
                '--node-ip', self.args.node_ip, '--bastion-ip', self.args.bastion_ip,
                '--gateway', self.args.gateway, '--prefix-length', '24',
                '--expected-mac', self.args.expected_mac, '--mirror-hostname', 'mirror.test',
                '--ca-file', str(ca), '--evidence', str(evidence)]

    def test_public_cli_requires_all_routed_inputs_and_never_accepts_vid(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            ca = base / 'ca'
            ca.touch()
            argv = self.argv(ca, base / 'result.json')
            variants = []
            for flag in ('--gateway', '--prefix-length', '--expected-mac'):
                i = argv.index(flag)
                variants.append(argv[:i] + argv[i + 2:])
            variants.append(argv + ['--vid', '2032'])
            for changed in variants:
                with self.subTest(argv=changed), contextlib.redirect_stderr(io.StringIO()), \
                        patch.object(link, 'check_path') as path, self.assertRaises(SystemExit):
                    link.main(changed)
                path.assert_not_called()

    def test_point_to_point_prefix_accepts_both_addresses_but_not_an_unrelated_gateway(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            ca = base / 'ca'
            ca.touch()
            argv = self.argv(ca, base / 'result.json')
            argv[argv.index('--prefix-length') + 1] = '31'
            argv[argv.index('--gateway') + 1] = '192.0.2.10'
            with patch.object(link, 'check_path', side_effect=ValueError('fixture path stops before probes')), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(link.main(argv), 1)
            self.assertEqual(json.loads((base / 'result.json').read_text())['inputs']['prefix_length'], '31')
            argv[argv.index('--gateway') + 1] = '192.0.2.1'
            with patch.object(link, 'check_path') as path, contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit):
                link.main(argv)
            path.assert_not_called()

    def test_routed_evidence_names_gateway_arp_without_claiming_private_vlan(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            ca = base / 'ca'
            ca.touch()
            evidence = base / 'result.json'
            with patch.object(link, 'check_path'), patch.object(link, 'check_tls'), \
                    patch.object(link, 'check_dns'), patch.object(link, 'check_ntp'), \
                    patch.object(link, 'check_arp'), contextlib.redirect_stdout(io.StringIO()) as output:
                # Return serializable details while exercising mode selection and evidence.
                with patch.object(link, 'write_evidence', wraps=link.write_evidence):
                    for fn in (link.check_path, link.check_tls, link.check_dns, link.check_ntp, link.check_arp):
                        fn.return_value = {}
                    self.assertEqual(link.main(self.argv(ca, evidence)), 0)
            result = json.loads(evidence.read_text())
            self.assertIn('gatewayARP', result['checks'])
            self.assertNotIn('ARP', result['checks'])
            self.assertNotIn('interface/source/VID', result['checks'])
            self.assertIn('no private VLAN', result['scope'])
            self.assertIn('no private VLAN proof', output.getvalue())
            self.assertEqual(evidence.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
