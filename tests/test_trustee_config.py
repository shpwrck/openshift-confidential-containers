"""Offline trust-boundary tests: no kubeconfig, credentials, network or containers."""
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import unittest
import tempfile
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "scripts/lib/trustee_config.py"
spec = importlib.util.spec_from_file_location("trustee_config", MODULE)
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)

TOML = '''[http_server]
insecure_http = false
[admin]
authorization_mode = "DenyAll"
[attestation_token]
insecure_header_jwk = false
[storage_backend]
storage_type = "LocalFs"
[attestation_service.verifier_config.snp_verifier]
vcek_sources = [
  { type = "OfflineStore" },
  { type = "KDS" }
]
custom_flag = true
[[plugins]]
name = "resource"
storage_backend_type = "kvstorage"
[[plugins]]
name = "custom"
option = "preserve me"
'''


CPU = '''package policy
import rego.v1
default executables := 33
default hardware := 97
default configuration := 36
executables := 3 if { input.snp.measurement in query_reference_value("snp_launch_measurement") }
hardware := 2 if {
  input.snp.reported_tcb_bootloader in query_reference_value("snp_bootloader")
  input.snp.reported_tcb_microcode in query_reference_value("snp_microcode")
  input.snp.reported_tcb_snp in query_reference_value("snp_snp_svn")
  input.snp.reported_tcb_tee in query_reference_value("snp_tee_svn")
}
configuration := 3 if { input.snp.policy_debug_allowed == false }
trust_claims := {
  "executables": executables,
  "hardware": hardware,
  "configuration": configuration,
}
'''


def generated():
    owner = {"kind": "TrusteeConfig", "uid": "tc-uid", "controller": True}
    tc = {"metadata": {"uid": "tc-uid"}}
    kbs = {"metadata": {"name": "trustee-config", "resourceVersion": "7", "ownerReferences": [owner]}, "spec": {field: "tc-" + key for key, (field, _) in t.FIELDS.items()}}
    maps = {kbs["spec"][field]: {"metadata": {"name": kbs["spec"][field], "ownerReferences": [owner], "annotations": {t.MIGRATION: "v1.2.0"}}, "data": {key: "example"}} for field, key in t.FIELDS.values()}
    return tc, kbs, maps


def record(name="snp_launch_measurement", value=None):
    return {"version": "0.1.0", "name": name, "expiration": "2099-01-01T00:00:00Z", "value": value if value is not None else ["a" * 96]}


class TrusteeConfigTests(unittest.TestCase):
    def test_customer_default_requires_both_distinct_tls_identities(self):
        with patch.dict(os.environ, {}, clear=True):
            spec = t.trustee_manifest()["spec"]
        self.assertEqual(spec["profileType"], "Restricted")
        self.assertNotEqual(spec["httpsSpec"], spec["attestationTokenVerificationSpec"])

    def test_permissive_profile_requires_explicit_lab_opt_in(self):
        with patch.dict(os.environ, {"TRUSTEE_PROFILE": "Permissive"}, clear=True):
            with self.assertRaisesRegex(ValueError, "TRUSTEE_LAB"):
                t.trustee_manifest()
            os.environ["TRUSTEE_LAB"] = "1"
            self.assertNotIn("httpsSpec", t.trustee_manifest()["spec"])

    def test_no_adoption_of_manual_or_other_owned_kbsconfig(self):
        tc, kbs, _ = generated()
        payload = {"trustee": tc, "kbsconfigs": {"items": [kbs]}}
        self.assertEqual(t.selected_kbs(payload), kbs)
        kbs["metadata"]["ownerReferences"] = []
        with self.assertRaisesRegex(ValueError, "explicit migration"):
            t.selected_kbs(payload)
        payload["kbsconfigs"]["items"] *= 2
        with self.assertRaisesRegex(ValueError, "exactly one"):
            t.selected_kbs(payload)

    def test_customization_waits_for_every_owned_migrated_map(self):
        tc, kbs, maps = generated()
        payload = {"trustee": tc, "kbs": kbs, "maps": maps}
        t.ready_configmaps(payload)
        cm = maps["tc-cpu"]
        del cm["metadata"]["annotations"][t.MIGRATION]
        with self.assertRaisesRegex(ValueError, "migration is not complete"):
            t.ready_configmaps(payload)
        cm["metadata"]["annotations"][t.MIGRATION] = "v1.2.0"
        cm["metadata"]["ownerReferences"] = []
        with self.assertRaisesRegex(ValueError, "unexpected owner"):
            t.ready_configmaps(payload)

    def test_snp_patch_disables_kds_and_preserves_unrelated_semantics(self):
        after = t.patch_toml(TOML, "snp")
        parsed = t.tomllib.loads(after)
        verifier = parsed["attestation_service"]["verifier_config"]["snp_verifier"]
        self.assertEqual(verifier, {"vcek_sources": [{"type": "OfflineStore"}], "custom_flag": True})
        self.assertEqual(parsed["plugins"][-1]["option"], "preserve me")
        self.assertEqual(t.patch_toml(after, "snp"), after)

    def test_restricted_features_reject_insecure_tokens_and_missing_core_references(self):
        tc, kbs, maps = generated()
        tc["spec"] = {"profileType": "Restricted"}
        for field in ("kbsHttpsKeySecretName", "kbsHttpsCertSecretName", "kbsAttestationKeySecretName", "kbsAttestationCertSecretName"):
            kbs["spec"][field] = "tls-input"
        maps["tc-config"]["data"]["kbs-config.toml"] = TOML.replace('insecure_header_jwk = false', 'insecure_header_jwk = false\ntrusted_certs_paths = ["/etc/attestation-cert/token.crt"]') + '''
[attestation_service.attestation_token_broker.signer]
key_path = "/etc/attestation-key/token.key"
cert_path = "/etc/attestation-cert/token.crt"
'''
        maps["tc-cpu"]["data"]["default_cpu.rego"] = CPU
        payload = {"trustee": tc, "kbs": kbs, "maps": maps}
        refs = [record(n) for n in t.restricted_cpu_features(CPU, "snp")]
        self.assertTrue(t.restricted_features(payload, "snp", refs)["restrictedFeaturesPresent"])
        with self.assertRaisesRegex(ValueError, "core platform references"):
            t.restricted_features(payload, "snp", [record()])
        maps["tc-config"]["data"]["kbs-config.toml"] = maps["tc-config"]["data"]["kbs-config.toml"].replace('insecure_header_jwk = false', 'insecure_header_jwk = true')
        with self.assertRaisesRegex(ValueError, "trusted token verification"):
            t.restricted_features(payload, "snp", refs)
        with self.assertRaisesRegex(ValueError, "CPU default"):
            t.restricted_cpu_features(CPU.replace("default hardware := 97", "default hardware := 2"), "snp")

    def test_serving_gate_requires_current_versions_new_uid_and_all_mounts(self):
        tc, kbs, maps = generated()
        del tc
        for cm in maps.values():
            cm["metadata"]["resourceVersion"] = "8"
        kbs["spec"].update(t.kbs_patch(kbs, "snp", ["a" * 128], ["credential"])["spec"])
        mount = kbs["spec"]["kbsLocalCertCacheSpec"]["secrets"][0]
        template = {"metadata": {"annotations": {t.VERSIONS: ",".join(f"{n}:8" for n in maps)}},
                    "spec": {"volumes": [{"name": "credential", "secret": {"secretName": "credential"}},
                                         {"name": "collateral", "secret": {"secretName": mount["secretName"]}}],
                             "containers": [{"volumeMounts": [{"name": "collateral", "mountPath": mount["mountPath"]}]}]}}
        pod = copy.deepcopy(template)
        pod["metadata"]["uid"] = "new"
        pod["status"] = {"conditions": [{"type": "Ready", "status": "True"}]}
        payload = {"kbs": kbs, "maps": maps, "old_uids": ["old"], "pods": {"items": [pod]},
                   "deployment": {"metadata": {"generation": 2}, "spec": {"replicas": 1, "template": template},
                                  "status": {"observedGeneration": 2, "updatedReplicas": 1, "availableReplicas": 1}}}
        self.assertTrue(t.serving_ready(payload)["ready"])
        stale = copy.deepcopy(payload)
        stale["pods"]["items"][0]["metadata"]["annotations"][t.VERSIONS] = "tc-config:7"
        with self.assertRaisesRegex(ValueError, "versions"):
            t.serving_ready(stale)
        stale = copy.deepcopy(payload)
        stale["pods"]["items"][0]["metadata"]["uid"] = "old"
        with self.assertRaisesRegex(ValueError, "new Ready"):
            t.serving_ready(stale)
        stale = copy.deepcopy(payload)
        stale["deployment"]["spec"]["template"]["spec"]["containers"][0]["volumeMounts"] = []
        with self.assertRaisesRegex(ValueError, "collateral mounts"):
            t.serving_ready(stale)

    def test_legacy_toml_is_not_silently_rewritten(self):
        with self.assertRaisesRegex(ValueError, "native Trustee 1.2"):
            t.patch_toml(TOML.replace('authorization_mode = "DenyAll"', 'type = "DenyAll"'), "snp")

    def test_merge_preserves_existing_resources_and_mounts_and_uses_cas(self):
        _, kbs, _ = generated()
        kbs["spec"]["kbsSecretResources"] = ["customer-secret"]
        kbs["spec"]["kbsLocalCertCacheSpec"] = {"secrets": [{"secretName": "custom-ca", "mountPath": "/etc/customer-ca"}]}
        original = copy.deepcopy(kbs)
        result = t.kbs_patch(kbs, "snp", ["a" * 128], ["credential"])
        self.assertEqual(result["spec"]["kbsSecretResources"], ["credential", "customer-secret"])
        self.assertEqual(result["spec"]["kbsLocalCertCacheSpec"]["secrets"][0], original["spec"]["kbsLocalCertCacheSpec"]["secrets"][0])
        self.assertEqual(result["metadata"]["resourceVersion"], "7")
        self.assertEqual(kbs, original)
        mount = t.vcek_mounts(["a" * 128])[0]
        mount["secretName"] = "different-certificate"
        kbs["spec"]["kbsLocalCertCacheSpec"]["secrets"] = [mount]
        with self.assertRaisesRegex(ValueError, "conflicts"):
            t.kbs_patch(kbs, "snp", ["a" * 128], [])

    def test_reference_conversion_is_lossless_for_typed_values(self):
        records = [record(), record("snp_smt_enabled", False), record("snp_bootloader", 3)]
        result = t.rvps_values(records)
        self.assertEqual([json.loads(base64.b64decode(result[r["name"]])) for r in records], records)
        self.assertEqual(t.rvps_values(result), result)
        cm = {"kind": "ConfigMap", "data": {"reference-values.json": json.dumps(records)}}
        self.assertEqual(t.rvps_values(cm), result)

    def test_rejects_duplicate_malformed_empty_or_expired_reference_sets(self):
        bad = [[], [record(), record()], {"wrong": base64.b64encode(json.dumps(record()).encode()).decode()}, {"x": "!invalid-base64"}, [dict(record(), expiration="2000-01-01T00:00:00Z")], [dict(record(), value=[])]]
        for data in bad:
            with self.subTest(data=data), self.assertRaises((ValueError, KeyError)):
                t.rvps_values(data)

    def test_duplicate_object_keys_and_nonobject_records_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "references.json"
            path.write_text('{"a": "first", "a": "second"}')
            with self.assertRaisesRegex(ValueError, "duplicate"):
                t.load_document(path)
            path.write_text('kind: ConfigMap\ndata:\n  reference_value: "{}"\n  reference_value: "{}"\n')
            with self.assertRaisesRegex(ValueError, "duplicate"):
                t.load_document(path)
        for values in (["not a record"], {"x": base64.b64encode(b'[]').decode()}):
            with self.subTest(values=values), self.assertRaisesRegex(ValueError, "must be an object"):
                t.rvps_values(values)

    def test_rejects_ambiguous_configmap_keys_and_old_record_structure(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            t.rvps_values({"kind": "ConfigMap", "data": {"reference_value": "{}", "reference-values.json": "[]"}})
        legacy = record()
        del legacy["value"]
        legacy["hash-value"] = [{"alg": "sha384", "value": "abc"}]
        with self.assertRaisesRegex(ValueError, "nonempty value"):
            t.rvps_values([legacy])


if __name__ == "__main__":
    unittest.main()
