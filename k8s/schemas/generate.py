#!/usr/bin/env python3
"""Turn CRDs (multi-document YAML on stdin) into kubeconform JSON schemas.

Writes <out>/<group>/<kind>_<version>.json, matching the kubeconform
schema-location template
  k8s/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

Objects with declared properties get additionalProperties: false (like
kubeconform's openapi2jsonschema in strict mode), so unknown fields fail.

Usage:
  helm template pc sigstore/policy-controller --version 0.10.8 \
    | python3 k8s/schemas/generate.py k8s/schemas
"""
import json
import os
import sys

import yaml


def strict(node):
    if isinstance(node, dict):
        if (
            "properties" in node
            and "additionalProperties" not in node
            and not node.get("x-kubernetes-preserve-unknown-fields")
        ):
            node["additionalProperties"] = False
        for value in node.values():
            strict(value)
    elif isinstance(node, list):
        for value in node:
            strict(value)
    return node


def main(out):
    for doc in yaml.safe_load_all(sys.stdin):
        if not doc or doc.get("kind") != "CustomResourceDefinition":
            continue
        spec = doc["spec"]
        group, kind = spec["group"], spec["names"]["kind"].lower()
        for version in spec["versions"]:
            schema = strict(version["schema"]["openAPIV3Schema"])
            # apiVersion, kind and metadata are checked by the API server.
            schema.setdefault("properties", {}).update(
                {"apiVersion": {"type": "string"}, "kind": {"type": "string"}, "metadata": {"type": "object"}}
            )
            path = os.path.join(out, group, f"{kind}_{version['name']}.json")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                json.dump(schema, f, indent=1, sort_keys=True)
                f.write("\n")
            print(path)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "k8s/schemas")
