#!/usr/bin/env python3

import argparse
from pathlib import Path

import jsonschema
import yaml


OFFICIAL_COMPONENT_VERSIONS = {
    "neon-broker",
    "neon-compute",
    "neon-pageserver",
    "neon-safekeeper",
}
EXPECTED_COMPONENT_VERSIONS = OFFICIAL_COMPONENT_VERSIONS | {"neon-future"}
EXPECTED_PATCH = [
    {
        "op": "add",
        "path": "/spec/releases/0/changes",
        "value": "",
    },
    {
        "op": "remove",
        "path": "/spec/releases/0/changes",
    },
]


def load_documents(path: Path) -> list[dict]:
    with path.open() as stream:
        return [document for document in yaml.safe_load_all(stream) if document]


def write_kustomization(
    helm_release_path: Path, resource_path: Path, destination_path: Path
) -> None:
    helm_release = load_documents(helm_release_path)[0]
    patches = helm_release["spec"]["postRenderers"][0]["kustomize"]["patches"]
    component_version_patches = [
        patch
        for patch in patches
        if patch["target"].get("group") == "apps.kubeblocks.io"
        and patch["target"].get("version") == "v1"
        and patch["target"].get("kind") == "ComponentVersion"
    ]
    if len(component_version_patches) != 1:
        raise AssertionError("expected exactly one ComponentVersion post-render patch")
    component_version_patch = component_version_patches[0]
    if component_version_patch["target"].get("name") != "neon-.*":
        raise AssertionError("ComponentVersion target name must be neon-.*")
    if yaml.safe_load(component_version_patch["patch"]) != EXPECTED_PATCH:
        raise AssertionError(
            "ComponentVersion patch must add empty changes and then remove changes"
        )
    kustomization = {
        "apiVersion": "kustomize.config.k8s.io/v1beta1",
        "kind": "Kustomization",
        "resources": [resource_path.name],
        "patches": patches,
    }
    with destination_path.open("w") as stream:
        yaml.safe_dump(kustomization, stream, sort_keys=False)


def validate_component_versions(rendered_path: Path, crd_path: Path) -> None:
    component_versions = {
        document["metadata"]["name"]: document
        for document in load_documents(rendered_path)
        if document.get("apiVersion") == "apps.kubeblocks.io/v1"
        and document.get("kind") == "ComponentVersion"
    }
    if set(component_versions) != EXPECTED_COMPONENT_VERSIONS:
        raise AssertionError(
            "expected ComponentVersions "
            f"{sorted(EXPECTED_COMPONENT_VERSIONS)}, got {sorted(component_versions)}"
        )

    component_version_crd = next(
        document
        for document in load_documents(crd_path)
        if document.get("kind") == "CustomResourceDefinition"
        and document["metadata"]["name"] == "componentversions.apps.kubeblocks.io"
    )
    version = next(
        version
        for version in component_version_crd["spec"]["versions"]
        if version["name"] == "v1"
    )
    validator = jsonschema.Draft7Validator(version["schema"]["openAPIV3Schema"])

    for name, component_version in component_versions.items():
        validator.validate(component_version)
        for release in component_version["spec"]["releases"]:
            if "changes" in release:
                raise AssertionError(
                    f"{name} release {release['name']} still contains changes"
                )


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    write_parser = subparsers.add_parser("write-kustomization")
    write_parser.add_argument("helm_release", type=Path)
    write_parser.add_argument("resource", type=Path)
    write_parser.add_argument("destination", type=Path)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("rendered", type=Path)
    validate_parser.add_argument("crd", type=Path)

    args = parser.parse_args()
    if args.command == "write-kustomization":
        write_kustomization(args.helm_release, args.resource, args.destination)
    else:
        validate_component_versions(args.rendered, args.crd)


if __name__ == "__main__":
    main()
