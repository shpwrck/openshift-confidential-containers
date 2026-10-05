# Experimental public routed lab profile

`public-routed-lab` currently supports configuration rendering and isolated installer
manifest validation. **Boot artifact publication and new reinstall requests are blocked.**
Protection for both the agent live environment and installed RHCOS must be implemented and
validated before those guards can change. This profile does not establish disconnected
operation or host, pod, Trustee or confidential-guest egress isolation.

The default remains `private-vlan`. Select the public profile explicitly when investigating
a routed alternative to an unavailable private VLAN. The public NIC carries the static node
address; the unused private NIC is down. DNS, NTP and the mirror use the bastion's public
address, reached through the node's provider gateway. The bastion is not that gateway.

## Inputs and rendering

Keep deployment inputs and rendered files outside the checkout. Use a separate, private
candidate directory so an experiment cannot replace active installer inputs or publication.
In the external rig YAML, retain the verified server identity, install disk, discovery inputs,
mirror credentials and boot token, and add these fields with values from the actual allocation:

```yaml
network_profile: public-routed-lab
node_public_ipv4: 192.0.2.11       # Example only; verify the provider's current primary IPv4.
node_public_prefix: 31           # Explicitly verified; there is no default netmask.
node_public_gateway: 192.0.2.10   # Verify the allocated host/provider network configuration.
bastion_public_ipv4: 198.51.100.9 # Example only; separate routed destination.
node_external_if: eno1          # Verify public NIC name and role=external MAC on this host.
node_parent_if: eno2            # Verify private NIC name and role=internal MAC on this host.
air_gap: false
enforce_node_egress: false
install_src_dir: /opt/coco-validation/public-lab/src
cluster_assets_dir: /opt/coco-validation/public-lab/cluster-assets
```

The example addresses are documentation ranges, not usable rig addresses. MAC discovery must
match the current allocation; neither the NIC name nor an old cached MAC proves identity.
The provider server API may expose the primary address and MAC without a gateway/netmask.
In that case verify those two inputs from the allocated host's current network configuration;
do not describe them as API-verified values.

The current profile requires exactly one master, one control-plane replica and zero compute
replicas. Its explicit IPv4 `/31` gateway must be the other address in that subnet. The renderer
derives the canonical `machineNetwork` from this pair, rather than using the private
`machine_network` default. It rejects overlap with cluster/service networks, missing or aliased
NIC identities, stale private DNS/NTP/rendezvous inputs, and either isolation flag enabled.
IPv6 is disabled on these two interfaces in the candidate.

`cluster_node_ip` and `bastion_service_ip` select the profile's addresses. The defaults use
`bastion_service_ip` for `additional_ntp_sources` and `cluster_node_ip` for the console proxy's
upstream. Do not override these aliases with private addresses for a public candidate.
The mirror hostname, certificate trust, digest mappings and mirror-only pull secret remain
unchanged. Mirror-only credentials do not restrict network egress.

After verifying the external inventory and discovery, run only the renderer:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook \
  ansible/playbooks/site.yml --tags render \
  -e @/absolute/private/state/public-lab.yml
```

This command creates private source YAML. It does not configure public DNS/NTP service access
or a firewall. Keep the selected source/assets directories separate from the active deployment.
Do not use an untagged install run to test this profile. Cleanup remains available through
`pxe_mode=stop` / the `pxe-stop` tag even when the selected profile cannot publish artifacts.

## Evidence and remaining acceptance work

On October 5, 2026, the pinned OpenShift installer **4.20.39**, build
`0b42839adc0600397af50204d4efb6b173ea1bbe`, accepted an isolated public `/31` candidate with
`agent create cluster-manifests`. Readback of the generated manifests retained the static
public NIC/MAC/address, provider gateway, canonical `/31` machine network, public bastion
DNS/NTP targets and disabled private NIC. That experiment preceded the reusable profile;
o live node boot or network activation was attempted. The installer warned that release
image architecture validation was skipped; this result is schema/manifest acceptance only.

The [OpenShift 4.20 Agent-based Installer preparation documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installing_an_on-premise_cluster_with_the_agent-based_installer/preparing-to-install-with-agent-based-installer)
describes static host network configuration. It does not turn this experimental topology into
an isolated network. Before proceeding, the lab still needs:

- Bastion service reachability restricted to the intended node and administration paths,
  including DNS, NTP and mirror TLS with the existing trusted hostname.
- Node ingress protection during the live installer and after RHCOS installation; a Latitude
  firewall object or assignment alone does not prove host enforcement.
- Fresh checks on the exact public NIC and source address, with both ordinary and exact-flow
  routes using the reviewed gateway, plus DNS/NTP/TLS protocol checks. Routed reachability
  must not be reported as private VLAN forwarding success.
- An actual boot, cluster health, mirror use and persistence checks. Any later egress policy
  needs separate host, pod and confidential-guest negative controls, including after reboot.

The existing airgap-egress MachineConfig filters host OUTPUT traffic only and assumes private
service destinations. Applying it unchanged would block the public bastion; it cannot establish
this profile's pod or guest isolation. See the [Latitude validation guide](latitude-validation.md)
for the default private topology and evidence boundaries.
