#!/usr/bin/env python3

import hashlib
import unittest
from pathlib import Path

import yaml
from jsonschema import Draft7Validator


REPO_ROOT = Path(__file__).resolve().parents[1]
OFFICIAL_KUBEBLOCKS_CRD_SHA256 = (
    "85a306c722244a4bee28dba8df8637512a7ee089fed43982ce673a6c87e68d1f"
)


def load_yaml(relative_path: str) -> dict:
    path = REPO_ROOT / relative_path
    with path.open(encoding="utf-8") as source:
        document = yaml.safe_load(source)
    if not isinstance(document, dict):
        raise AssertionError(f"{relative_path} must contain one YAML object")
    return document


def format_validation_errors(errors) -> str:
    messages = []
    for error in errors:
        location = ".".join(str(part) for part in error.absolute_path) or "<root>"
        messages.append(f"{location}: {error.message}")
    return "\n".join(messages)


class KubeBlocksNeonContracts(unittest.TestCase):
    def test_cluster_uses_the_kubeblocks_v1_definition_field(self):
        cluster = load_yaml("clusters/home/resources/neon-demo.yaml")

        self.assertEqual(cluster["apiVersion"], "apps.kubeblocks.io/v1")
        self.assertEqual(cluster["spec"].get("clusterDef"), "neon")
        self.assertNotIn("clusterDefinitionRef", cluster["spec"])

    def test_component_specs_match_kubeblocks_normalized_contract(self):
        cluster = load_yaml("clusters/home/resources/neon-demo.yaml")

        normalized_components = [
            {
                key: component.get(key)
                for key in ("name", "componentDef", "serviceVersion")
            }
            for component in cluster["spec"]["componentSpecs"]
        ]

        self.assertEqual(
            normalized_components,
            [
                {
                    "name": "neon-pageserver",
                    "componentDef": "neon-pageserver-1.0.1",
                    "serviceVersion": "1.0.0",
                },
                {
                    "name": "neon-safekeeper",
                    "componentDef": "neon-safekeeper-1.0.1",
                    "serviceVersion": "1.0.0",
                },
                {
                    "name": "neon-broker",
                    "componentDef": "neon-broker-1.0.1",
                    "serviceVersion": "1.0.0",
                },
                {
                    "name": "neon-compute",
                    "componentDef": "neon-compute-1.0.1",
                    "serviceVersion": "1.0.0",
                },
            ],
        )

    def test_component_storage_matches_the_neon_1_0_1_mount_contract(self):
        cluster = load_yaml("clusters/home/resources/neon-demo.yaml")
        components = {
            component["name"]: component
            for component in cluster["spec"]["componentSpecs"]
        }
        expected_replicas = {
            "neon-broker": 1,
            "neon-pageserver": 1,
            "neon-safekeeper": 3,
            "neon-compute": 1,
        }

        self.assertEqual(set(components), set(expected_replicas))
        for name, replicas in expected_replicas.items():
            with self.subTest(component=name, contract="replicas-and-resources"):
                component = components[name]
                self.assertEqual(component["replicas"], replicas)
                self.assertEqual(
                    component["resources"],
                    {
                        "requests": {"cpu": "500m", "memory": "512Mi"},
                        "limits": {"cpu": "1", "memory": "2Gi"},
                    },
                )

        expected_claims = {
            "neon-pageserver": "10Gi",
            "neon-safekeeper": "5Gi",
            "neon-compute": "5Gi",
        }
        for name, capacity in expected_claims.items():
            with self.subTest(component=name, contract="data-volume"):
                claims = components[name].get("volumeClaimTemplates")
                self.assertIsInstance(claims, list)
                self.assertEqual(len(claims), 1)
                self.assertEqual(claims[0]["name"], "data")
                self.assertEqual(claims[0]["spec"]["accessModes"], ["ReadWriteOnce"])
                self.assertEqual(
                    claims[0]["spec"]["storageClassName"], "rook-ceph-block"
                )
                self.assertEqual(
                    claims[0]["spec"]["resources"]["requests"]["storage"], capacity
                )

        self.assertNotIn("volumeClaimTemplates", components["neon-broker"])

    def test_all_components_are_scheduled_on_amd64_nodes(self):
        cluster = load_yaml("clusters/home/resources/neon-demo.yaml")

        self.assertEqual(
            cluster["spec"]["schedulingPolicy"]["nodeSelector"],
            {"kubernetes.io/arch": "amd64"},
        )
        for component in cluster["spec"]["componentSpecs"]:
            with self.subTest(component=component["name"]):
                self.assertNotIn("schedulingPolicy", component)

    def test_core_release_disables_built_in_addon_management(self):
        release = load_yaml("components/kubeblocks/release.yaml")

        self.assertEqual(release["spec"]["chart"]["spec"]["version"], "1.0.2")
        values = release["spec"].get("values", {})
        self.assertIs(values.get("addonController", {}).get("enabled"), False)
        self.assertEqual(values.get("autoInstalledAddons"), [])

    def test_official_v1_0_0_crds_are_vendored_with_the_v1_cluster_schema(self):
        component_path = REPO_ROOT / "components/kubeblocks-crds/kustomization.yaml"
        bundle_path = REPO_ROOT / "components/kubeblocks-crds/kubeblocks_crds.yaml"
        self.assertTrue(component_path.is_file(), f"missing {component_path}")
        self.assertTrue(bundle_path.is_file(), f"missing {bundle_path}")

        component = load_yaml("components/kubeblocks-crds/kustomization.yaml")
        self.assertEqual(component["kind"], "Component")
        self.assertEqual(component["resources"], ["kubeblocks_crds.yaml"])

        with bundle_path.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        self.assertEqual(digest, OFFICIAL_KUBEBLOCKS_CRD_SHA256)

        with bundle_path.open(encoding="utf-8") as source:
            crds = {
                document["metadata"]["name"]: document
                for document in yaml.safe_load_all(source)
                if isinstance(document, dict)
                and document.get("kind") == "CustomResourceDefinition"
            }

        required_crds = {
            "clusterdefinitions.apps.kubeblocks.io",
            "clusters.apps.kubeblocks.io",
            "componentdefinitions.apps.kubeblocks.io",
            "components.apps.kubeblocks.io",
        }
        self.assertTrue(required_crds.issubset(crds))

        for name in required_crds:
            with self.subTest(crd=name):
                version = next(
                    item
                    for item in crds[name]["spec"]["versions"]
                    if item["name"] == "v1"
                )
                self.assertIs(version["served"], True)
                self.assertIs(version["storage"], True)

        cluster_version = next(
            item
            for item in crds["clusters.apps.kubeblocks.io"]["spec"]["versions"]
            if item["name"] == "v1"
        )
        cluster_schema = cluster_version["schema"]["openAPIV3Schema"]
        spec_properties = cluster_schema["properties"]["spec"]["properties"]
        self.assertIn("clusterDef", spec_properties)
        self.assertNotIn("clusterDefinitionRef", spec_properties)

        cluster = load_yaml("clusters/home/resources/neon-demo.yaml")
        errors = sorted(
            Draft7Validator(cluster_schema).iter_errors(cluster),
            key=lambda error: list(error.absolute_path),
        )
        self.assertFalse(errors, format_validation_errors(errors))

    def test_flux_applies_crds_before_core_and_parent_waits_for_core(self):
        crds_path = REPO_ROOT / "clusters/home/controllers/kubeblocks-crds.yaml"
        self.assertTrue(crds_path.is_file(), f"missing {crds_path}")

        crds = load_yaml("clusters/home/controllers/kubeblocks-crds.yaml")
        core = load_yaml("clusters/home/controllers/kubeblocks.yaml")
        parent = load_yaml("clusters/home/configs/_next.yaml")
        resources = load_yaml("clusters/home/controllers/_next.yaml")

        self.assertEqual(crds["metadata"]["name"], "kubeblocks-crds")
        self.assertEqual(crds["metadata"]["namespace"], "flux-system")
        self.assertEqual(crds["spec"]["path"], "components/kubeblocks-crds")
        self.assertIs(crds["spec"]["wait"], True)
        self.assertEqual(crds["spec"]["timeout"], "10m")

        self.assertEqual(core["spec"].get("dependsOn"), [{"name": "kubeblocks-crds"}])
        self.assertEqual(parent["metadata"]["name"], "cluster-controllers")
        self.assertEqual(parent["spec"].get("dependsOn"), [{"name": "cluster-configs"}])
        self.assertEqual(parent["spec"]["timeout"], "15m")
        self.assertEqual(
            parent["spec"].get("healthChecks"),
            [
                {
                    "apiVersion": "kustomize.toolkit.fluxcd.io/v1",
                    "kind": "Kustomization",
                    "name": "kubeblocks",
                    "namespace": "flux-system",
                }
            ],
        )
        self.assertEqual(
            resources["spec"].get("dependsOn"), [{"name": "cluster-controllers"}]
        )

    def test_flux_objects_match_the_checked_in_flux_crd_schemas(self):
        gotk_path = REPO_ROOT / "clusters/home/_system/flux-system/gotk-components.yaml"
        with gotk_path.open(encoding="utf-8") as source:
            crds = [
                document
                for document in yaml.safe_load_all(source)
                if isinstance(document, dict)
                and document.get("kind") == "CustomResourceDefinition"
            ]

        schemas = {}
        for crd in crds:
            group = crd["spec"]["group"]
            kind = crd["spec"]["names"]["kind"]
            for version in crd["spec"]["versions"]:
                if version.get("schema"):
                    schemas[(f"{group}/{version['name']}", kind)] = version["schema"][
                        "openAPIV3Schema"
                    ]

        manifest_paths = [
            "clusters/home/controllers/kubeblocks-crds.yaml",
            "clusters/home/controllers/kubeblocks.yaml",
            "clusters/home/configs/_next.yaml",
            "clusters/home/controllers/_next.yaml",
            "components/kubeblocks/repository.yaml",
            "components/kubeblocks/release.yaml",
            "components/kubeblocks/neon-release.yaml",
        ]
        for relative_path in manifest_paths:
            with self.subTest(manifest=relative_path):
                path = REPO_ROOT / relative_path
                self.assertTrue(path.is_file(), f"missing {path}")
                manifest = load_yaml(relative_path)
                schema_key = (manifest["apiVersion"], manifest["kind"])
                self.assertIn(schema_key, schemas)
                errors = sorted(
                    Draft7Validator(schemas[schema_key]).iter_errors(manifest),
                    key=lambda error: list(error.absolute_path),
                )
                self.assertFalse(errors, format_validation_errors(errors))


if __name__ == "__main__":
    unittest.main(verbosity=2)
