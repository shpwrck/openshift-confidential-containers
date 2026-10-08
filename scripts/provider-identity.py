#!/usr/bin/env python3
"""Validate an exact provider response supplied on stdin; print only public identity fields."""
import argparse
import json
import sys
from lib.provider import server_identity

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--provider", required=True, choices=["latitude", "cherry"])
parser.add_argument("--server-id", required=True)
parser.add_argument("--hostname", default="")
parser.add_argument("--project-id", default="")
args = parser.parse_args()
try:
    print(json.dumps(server_identity(args.provider, json.load(sys.stdin), args.server_id,
                                    args.hostname, args.project_id)))
except (ValueError, KeyError, TypeError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
