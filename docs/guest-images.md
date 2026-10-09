# Guest registry access

A confidential pod pulls its workload image inside the VM. Configure **both**
host and guest registry access: the cluster's mirror resources and pull secret do
not supply the guest's registry credentials, remaps or CA.

## Required guest inputs

The [workload renderer](../scripts/render-workload.py) builds initdata for the selected
endpoint and image policy. Its annotation key is
`io.katacontainers.config.hypervisor.cc_init_data`.

| Input | Purpose |
|---|---|
| `aa.toml` and `cdh.toml` | Attestation/data-hub configuration and KBS endpoint |
| `authenticated_registry_credentials_uri` | KBS resource containing registry auth |
| `image_security_policy_uri` | KBS resource containing the guest image acceptance policy |
| `registry_configuration_uri` | KBS resource containing `registries.conf` mirror remaps |
| `extra_root_certificates` | Public registry CA certificates, one PEM certificate per array entry |
| `policy.rego` | Complete reviewed Kata Agent policy for the workload |

Use HTTPS and the endpoint CA in customer mode. Resource URIs are
`kbs:///default/<secret>/<key>`; their names/keys must match the Secrets attached
to the actual KbsConfig. [Trustee setup](trustee-current.md) explains that publication.

The registry credential must match the remapped `host:port` and contain inline
Docker `auth` material; a workstation credential helper is not available in the
guest. Keep the credential in KBS, never in initdata. The image policy needs its
`transports` structure as well as `default`.

Remap every guest-pulled image, including sandbox/pause and release images when
applicable. Use `registry_configuration_uri` rather than an inline
`[image.registry_config]` table. Avoid `insecure=true`: the tested guest client can
interpret it as HTTP, which fails against a TLS-only registry.

## TLS and DNS

Check that the registry sends its leaf and required intermediate certificates,
and that its hostname/SAN matches the image endpoint. A directly root-signed leaf
needs no intermediate; counting certificates alone cannot diagnose a broken chain.
Verify with the intended root CA:

```bash
openssl s_client -connect registry.example.internal:8443 \
  -servername registry.example.internal -showcerts </dev/null
curl --cacert "$COCO_STATE_DIR/mirror-ca.pem" \
  https://registry.example.internal:8443/v2/
```

A trusted `401` from `/v2/` establishes TLS reachability, not authenticated image pull.
Guest trust is distinct from host trust; each must pass. The historical multi-certificate
array comparison did not complete a valid hardware control matrix, so no new runtime
claim is made for that experiment.

Cluster DNS must resolve the registry and KBS names from ordinary pods and guests.
The maintained lab renderer can configure its explicit DNS forwarder; customer
DNS changes require the customer's own approved configuration.

## Artifactory

The same guest inputs apply, but repository paths and authentication must match the
customer's Artifactory Docker endpoint. Stage the required digests in local repositories;
an upstream-backed repository can still fail on an offline cache miss. Inspect registry
request logs to distinguish authentication, policy denial and missing manifests.

Artifactory was not validated in the October 8 trial. Prepare customer resources
out of band in Restricted Trustee; the synthetic lab seeder is not a customer
credential tool. Test a positive pull before drawing conclusions from a negative one.
See [signed-image tests](capability-status.md#signed-images) and
[troubleshooting](troubleshooting.md) for the acceptance checks.
