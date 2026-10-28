# Offline tests

These tests need no cluster, credentials or AMD hardware. They run the real
scripts and Ansible tasks against fake `oc`, provider APIs, SSH targets and
files in temporary directories, so a change that would erase the wrong disk,
publish a secret or skip a security check fails here first.

Run everything (shell, policy, release and Ansible checks plus these tests):

```bash
make lint
```

Or run only the Python tests, or one module, after installing
[the development requirements](../docs/contributing.md):

```bash
python3 scripts/run-tests.py
python3 scripts/run-tests.py test_trustee_config
```

`scripts/run-tests.py` runs the modules side by side, one process each and as
many at once as there are CPUs, and prints the full output of any module that
failed. With four CPUs the suite takes under three minutes; one after another
(`python3 -m unittest discover -s tests -v`) it takes about eight, mostly in the
modules that run `ansible-playbook`. Run as a normal user: one permission check
is skipped as root, because root can read a directory with mode `000`.

| Area | Modules |
|---|---|
| Release manifest, mirror, cluster access and Operator selection | `test_release_manifest`, `test_mirror_resources`, `test_mirror_bootstrap`, `test_bootstrap_release`, `test_connect_cluster`, `test_worker_install`, `test_worker_safety` |
| Helper, network and install automation | `test_bastion_network`, `test_bastion_prerequisites`, `test_bonded_profile`, `test_boot_publication`, `test_bootstrap`, `test_chrony_config`, `test_install_resolver`, `test_install_private_link`, `test_private_link`, `test_render_helper_bootstrap` |
| Provider, ordering and hardware discovery | `test_cherry_provider`, `test_order_rig`, `test_discovery`, `test_host_snp_check`, `test_node_checks` |
| Trustee configuration and lifecycle | `test_trustee_lab`, `test_trustee_config`, `test_trustee_cli`, `test_trustee_lifecycle`, `test_veritas_node`, `test_vcek_bundle`, `test_review_references`, `test_policy_binding` |
| Workloads, image signing and the capability-test runner | `test_workload`, `test_signature_verifier`, `test_signed_policy`, `test_proof_core` |
| The parallel test runner | `test_run_tests` |
| Gatekeeper memory policy (Rego, needs `opa`) | `test-coco-mem-rego.sh` |

Passing tests do not show that attestation works. Only the
[capability tests](../docs/capability-status.md) on SEV-SNP hardware do that.
