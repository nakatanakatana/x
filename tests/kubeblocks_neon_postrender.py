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
EXPECTED_SECURITY_CONTEXT_PATCH = {
    "op": "add",
    "path": "/spec/runtime/securityContext",
    "value": {"fsGroup": 996, "fsGroupChangePolicy": "OnRootMismatch"},
}
EXPECTED_SECURITY_CONTEXT_COMPONENTS = {
    "neon-compute",
    "neon-pageserver",
    "neon-safekeeper",
}
EXPECTED_SECURITY_CONTEXT = {
    "fsGroup": 996,
    "fsGroupChangePolicy": "OnRootMismatch",
}


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
    for component in EXPECTED_SECURITY_CONTEXT_COMPONENTS:
        component_patches = [
            patch
            for patch in patches
            if patch["target"].get("group") == "apps.kubeblocks.io"
            and patch["target"].get("version") == "v1"
            and patch["target"].get("kind") == "ComponentDefinition"
            and patch["target"].get("name") == f"{component}-.*"
        ]
        if len(component_patches) != 1:
            raise AssertionError(
                f"expected exactly one {component} ComponentDefinition patch"
            )
        patch_operations = yaml.safe_load(component_patches[0]["patch"])
        if EXPECTED_SECURITY_CONTEXT_PATCH not in patch_operations:
            raise AssertionError(
                f"{component} patch must set the exact pod security context"
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


def validate_component_definition(
    rendered_path: Path, crd_path: Path, component_name: str
) -> None:
    component_definitions = [
        document
        for document in load_documents(rendered_path)
        if document.get("apiVersion") == "apps.kubeblocks.io/v1"
        and document.get("kind") == "ComponentDefinition"
        and document.get("metadata", {}).get("name") == component_name
    ]
    if len(component_definitions) != 1:
        raise AssertionError(
            f"expected exactly one rendered {component_name} ComponentDefinition"
        )
    component_definition = component_definitions[0]
    if (
        component_definition["spec"]["runtime"].get("securityContext")
        != EXPECTED_SECURITY_CONTEXT
    ):
        raise AssertionError(
            f"{component_name} runtime must have the exact pod security context"
        )

    component_definition_crd = next(
        document
        for document in load_documents(crd_path)
        if document.get("kind") == "CustomResourceDefinition"
        and document["metadata"]["name"] == "componentdefinitions.apps.kubeblocks.io"
    )
    version = next(
        version
        for version in component_definition_crd["spec"]["versions"]
        if version["name"] == "v1"
    )
    jsonschema.Draft7Validator(version["schema"]["openAPIV3Schema"]).validate(
        component_definition
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

    component_validate_parser = subparsers.add_parser("validate-component")
    component_validate_parser.add_argument("rendered", type=Path)
    component_validate_parser.add_argument("crd", type=Path)
    component_validate_parser.add_argument("component_name")

    args = parser.parse_args()
    if args.command == "write-kustomization":
        write_kustomization(args.helm_release, args.resource, args.destination)
    elif args.command == "validate":
        validate_component_versions(args.rendered, args.crd)
    else:
        validate_component_definition(args.rendered, args.crd, args.component_name)


if __name__ == "__main__":
    main()
