#!/usr/bin/env python3
"""Pure rendering/InstallPlan checks for the staged worker installer."""
import argparse
import json
from pathlib import Path
import sys
import yaml


def selected_operators(bom, tee, lab):
    keys = ["nfd", "certManager", "osc", "gatekeeper"]
    if lab:
        keys.append("trustee")
    return [bom["operators"][key] for key in keys]


def check_plan(plan, bom, tee, lab, expected_csv):
    operators = selected_operators(bom, tee, lab)
    allowed = set()
    for op in operators:
        if not op.get("startingCSV"):
            raise ValueError(f"unresolved startingCSV for {op['package']}")
        allowed.add(op["startingCSV"])
        allowed.update(op.get("dependencyCSVs", []))
    proposed = set(plan.get("spec", {}).get("clusterServiceVersionNames", []))
    if not proposed or expected_csv not in proposed or not proposed <= allowed:
        raise ValueError("InstallPlan CSV set is missing the expected CSV or contains unreviewed dependencies")
    if plan["spec"].get("approval") != "Manual":
        raise ValueError("InstallPlan must use Manual approval")
    sources = {bom["catalog"]["source"]}
    steps = plan.get("status", {}).get("plan", [])
    if not steps:
        raise ValueError("InstallPlan has no resolved steps; wait for OLM resolution")
    csv_steps = set()
    for step in steps:
        resource = step.get("resource", {})
        if resource.get("catalogSource") not in sources or resource.get("catalogSourceNamespace") != "openshift-marketplace":
            raise ValueError("InstallPlan step comes from an unexpected catalog")
        if resource.get("kind") == "ClusterServiceVersion":
            csv_steps.add(resource["name"])
    if csv_steps != proposed:
        raise ValueError("InstallPlan resolved CSV steps disagree with proposed CSV set")


def check_kata(state, bom, tee, topology):
    """Verify real OSC 1.13 status plus the selected nodes' current MCO state.

    KataConfig has no observedGeneration field. Status shape and MCO semantics:
    https://github.com/openshift/sandboxed-containers-operator/blob/osc-release-v1.13/api/v1/kataconfig_types.go
    https://github.com/openshift/sandboxed-containers-operator/blob/osc-release-v1.13/controllers/openshift_controller.go
    """
    profile = bom["profiles"][tee]
    key, value = profile["nodeLabel"].split("=", 1)
    labels = {key:value}
    if topology == "customer":
        labels[profile["workerPoolLabel"]] = profile["workerPoolValue"]
    kata, mcp, nodes = state["kata"], state["mcp"], state["nodes"]["items"]
    status = kata.get("status", {})
    counts = status.get("kataNodes", {})
    names = {n["metadata"]["name"] for n in nodes}
    if not names or len(names) != len(nodes):
        raise ValueError("no distinct selected Kata nodes")
    if kata.get("metadata", {}).get("deletionTimestamp") or kata.get("spec", {}).get("kataConfigPoolSelector") != {"matchLabels":labels}:
        raise ValueError("KataConfig is deleting or its selector differs from the requested pool")
    if kata["spec"].get("enablePeerPods") is not False:
        raise ValueError("KataConfig must use the bare-metal runtime")
    progress = [c for c in status.get("conditions", []) if c.get("type") == "InProgress"]
    if len(progress) != 1 or progress[0].get("status") != "False" or progress[0].get("reason") or status.get("waitingForMcoToStart", False):
        raise ValueError("KataConfig reconciliation is pending, failed or waiting for MCO")
    pending = ("installing", "waitingToInstall", "failedToInstall", "uninstalling", "waitingToUninstall", "failedToUninstall")
    if any(counts.get(field) for field in pending) or counts.get("nodeCount") != len(names) or counts.get("readyNodeCount") != len(names) or set(counts.get("installed", [])) != names:
        raise ValueError("KataConfig installed/ready node set does not match selected nodes")
    if profile["runtimeClass"] not in status.get("runtimeClasses", []) or state["runtime"].get("handler") != profile["runtimeHandler"]:
        raise ValueError("selected runtime is missing from KataConfig status or has the wrong handler")
    pool_status = mcp.get("status", {})
    config = mcp.get("spec", {}).get("configuration", {}).get("name")
    if not config or pool_status.get("observedGeneration", 0) < mcp["metadata"]["generation"] or pool_status.get("configuration", {}).get("name") != config:
        raise ValueError("Kata MCP has not observed/completed its current rendered configuration")
    if any(pool_status.get(field) != len(names) for field in ("machineCount", "readyMachineCount", "updatedMachineCount")) or pool_status.get("degradedMachineCount", 0) != 0:
        raise ValueError("Kata MCP node counts have not converged")
    conditions = {c["type"]:c["status"] for c in pool_status.get("conditions", [])}
    if any(conditions.get(k) != v for k, v in {"Updated":"True", "Updating":"False", "Degraded":"False"}.items()):
        raise ValueError("Kata MCP is not stable")
    for node in nodes:
        metadata = node["metadata"]
        if any(metadata.get("labels", {}).get(k) != v for k, v in labels.items()):
            raise ValueError("node no longer matches the requested Kata pool")
        annotation = metadata.get("annotations", {})
        prefix = "machineconfiguration.openshift.io/"
        if annotation.get(prefix+"state") != "Done" or annotation.get(prefix+"currentConfig") != config or annotation.get(prefix+"desiredConfig") != config:
            raise ValueError("selected node has not applied the Kata MCP rendered configuration")
        if not any(c.get("type") == "Ready" and c.get("status") == "True" for c in node.get("status", {}).get("conditions", [])):
            raise ValueError("selected Kata node is not Ready")


def transform(docs, mode, bom, tee, lab, topology="customer"):
    docs = [d for d in docs if d]
    if mode == "operators":
        if not lab:
            docs = [d for d in docs if d.get("metadata", {}).get("namespace") != "trustee-operator-system" and not (d.get("kind") == "Namespace" and d["metadata"]["name"] == "trustee-operator-system")]
        expected = {op["package"]:op for op in selected_operators(bom, tee, lab)}
        for doc in docs:
            if doc.get("kind") == "Subscription":
                op = expected[doc["spec"]["name"]]
                if not op.get("startingCSV"):
                    raise ValueError(f"unresolved CSV for {op['package']}")
                doc["spec"].update(startingCSV=op["startingCSV"], channel=op["channel"], installPlanApproval="Manual")
    elif mode in ("templates", "constraints"):
        wanted = mode == "templates"
        docs = [d for d in docs if (d.get("kind") == "ConstraintTemplate") == wanted]
        if not docs:
            raise ValueError(f"no {mode} in memory policy file")
    elif mode == "kata":
        profile = bom["profiles"][tee]
        key, value = profile["nodeLabel"].split("=", 1)
        labels = {key:value}
        if topology == "customer":
            labels[profile["workerPoolLabel"]] = profile["workerPoolValue"]
        for doc in docs:
            if doc.get("kind") == "KataConfig":
                doc["spec"]["kataConfigPoolSelector"] = {"matchLabels":labels}
    return docs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("operators", "templates", "constraints", "kata", "check-plan", "check-kata"))
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--tee", choices=("snp",), default="snp")
    parser.add_argument("--lab", action="store_true")
    parser.add_argument("--topology", choices=("sno", "customer"), default="customer")
    parser.add_argument("--expected-csv")
    args = parser.parse_args()
    try:
        bom = json.loads(args.manifest.read_text())
        if args.mode == "check-plan":
            check_plan(json.load(sys.stdin), bom, args.tee, args.lab, args.expected_csv)
        elif args.mode == "check-kata":
            check_kata(json.load(sys.stdin), bom, args.tee, args.topology)
        else:
            print(yaml.safe_dump_all(transform(yaml.safe_load_all(sys.stdin), args.mode, bom, args.tee, args.lab, args.topology), sort_keys=False), end="")
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as exc:
        print(f"ERROR: worker install: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
