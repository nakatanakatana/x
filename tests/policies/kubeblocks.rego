package manifest_policy

import rego.v1

required_kubeblocks_component_version_roles := {"broker", "compute", "pageserver", "safekeeper"}
required_kubeblocks_component_definition_roles := {"compute", "pageserver", "safekeeper"}
required_kubeblocks_s3_credentials := ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]
required_kubeblocks_s3_credential_env_names := [
	"AWS_ACCESS_KEY_ID",
	"AWS_SECRET_ACCESS_KEY",
	"RCLONE_CONFIG_NEON_ACCESS_KEY_ID",
	"RCLONE_CONFIG_NEON_SECRET_ACCESS_KEY",
]
kubeblocks_s3_credential_secret_keys := {
	"AWS_ACCESS_KEY_ID": "AWS_ACCESS_KEY_ID",
	"AWS_SECRET_ACCESS_KEY": "AWS_SECRET_ACCESS_KEY",
	"RCLONE_CONFIG_NEON_ACCESS_KEY_ID": "AWS_ACCESS_KEY_ID",
	"RCLONE_CONFIG_NEON_SECRET_ACCESS_KEY": "AWS_SECRET_ACCESS_KEY",
}
kubeblocks_s3_remote_keys := {
	"AWS_ACCESS_KEY_ID": "pcloud-s3/S3_ACCESS_KEY_ID",
	"AWS_SECRET_ACCESS_KEY": "pcloud-s3/S3_SECRET_ACCESS_KEY",
}
kubeblocks_s3_secret_name := "neon-s3-credentials"
kubeblocks_expected_replicas := {"broker": 1, "compute": 1, "pageserver": 1, "safekeeper": 3}
kubeblocks_expected_storage := {"compute": "5Gi", "pageserver": "10Gi", "safekeeper": "5Gi"}
kubeblocks_expected_resources := {
	"requests": {"cpu": "500m", "memory": "512Mi"},
	"limits": {"cpu": "1", "memory": "2Gi"},
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	container := object.get(object.get(object.get(resource.document, "spec", {}), "runtime", {}), "containers", [])[_]
	image := object.get(container, "image", "")
	image != ""
	not has_valid_sha256_digest(image)

	violation := {
		"policy": "kubeblocks-image-must-be-digest-pinned",
		"resource": resource_ref(resource.document),
		"path": "spec.runtime.containers[*].image",
		"message": "KubeBlocks runtime images must include a sha256 digest",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	container := object.get(object.get(object.get(resource.document, "spec", {}), "runtime", {}), "initContainers", [])[_]
	image := object.get(container, "image", "")
	image != ""
	not has_valid_sha256_digest(image)

	violation := {
		"policy": "kubeblocks-image-must-be-digest-pinned",
		"resource": resource_ref(resource.document),
		"path": "spec.runtime.initContainers[*].image",
		"message": "KubeBlocks init container images must include a sha256 digest",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_version(resource.document)
	release := object.get(object.get(resource.document, "spec", {}), "releases", [])[_]
	images := object.get(release, "images", {})
	image_name := object.keys(images)[_]
	image := images[image_name]
	image != ""
	not has_valid_sha256_digest(image)

	violation := {
		"policy": "kubeblocks-image-must-be-digest-pinned",
		"resource": resource_ref(resource.document),
		"path": "spec.releases[*].images",
		"message": sprintf("KubeBlocks release image %s must include a sha256 digest", [image_name]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	container := object.get(object.get(object.get(resource.document, "spec", {}), "runtime", {}), "containers", [])[_]
	image := object.get(container, "image", "")
	uses_latest_tag(image)

	violation := {
		"policy": "kubeblocks-image-must-not-use-latest",
		"resource": resource_ref(resource.document),
		"path": "spec.runtime.containers[*].image",
		"message": "KubeBlocks runtime images must not use an unpinned latest tag",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	container := object.get(object.get(object.get(resource.document, "spec", {}), "runtime", {}), "initContainers", [])[_]
	image := object.get(container, "image", "")
	uses_latest_tag(image)

	violation := {
		"policy": "kubeblocks-image-must-not-use-latest",
		"resource": resource_ref(resource.document),
		"path": "spec.runtime.initContainers[*].image",
		"message": "KubeBlocks init container images must not use an unpinned latest tag",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_version(resource.document)
	release := object.get(object.get(resource.document, "spec", {}), "releases", [])[_]
	images := object.get(release, "images", {})
	image_name := object.keys(images)[_]
	image := images[image_name]
	uses_latest_tag(image)

	violation := {
		"policy": "kubeblocks-image-must-not-use-latest",
		"resource": resource_ref(resource.document),
		"path": "spec.releases[*].images",
		"message": sprintf("KubeBlocks release image %s must not use an unpinned latest tag", [image_name]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	object.get(resource.document, "kind", "") == "HelmRelease"
	resource_name(resource.document) == "kubeblocks"
	values := object.get(object.get(resource.document, "spec", {}), "values", {})
	addon_controller := object.get(values, "addonController", {})
	object.get(addon_controller, "enabled", true) != false

	violation := {
		"policy": "kubeblocks-addon-controller-must-remain-disabled",
		"resource": resource_ref(resource.document),
		"path": "spec.values.addonController.enabled",
		"message": "KubeBlocks addonController must remain disabled",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	object.get(resource.document, "kind", "") == "HelmRelease"
	resource_name(resource.document) == "kubeblocks"
	values := object.get(object.get(resource.document, "spec", {}), "values", {})
	object.get(values, "autoInstalledAddons", null) != []

	violation := {
		"policy": "kubeblocks-auto-installed-addons-must-remain-empty",
		"resource": resource_ref(resource.document),
		"path": "spec.values.autoInstalledAddons",
		"message": "KubeBlocks autoInstalledAddons must remain empty",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_neon_script_config(resource.document)
	script := object.get(object.get(resource.document, "data", {}), "pageserver_start.sh", "")
	required := {
		"bucket_name='neon-demo'",
		"endpoint='http://gateway.pcloud-s3.svc.cluster.local:8080'",
		"bucket_region='us-east-1'",
		"prefix_in_bucket='pageserver'",
	}
	missing := required[_]
	not contains(script, missing)

	violation := {
		"policy": "kubeblocks-neon-remote-storage-must-match-contract",
		"resource": resource_ref(resource.document),
		"path": "data.pageserver_start.sh",
		"message": sprintf("Neon pageserver startup script must contain %s", [missing]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	object.get(resource.document, "spec", {}).serviceKind == "neon-pageserver"
	not kubeblocks_neon_rclone_runtime_contract(resource.document)

	violation := {
		"policy": "kubeblocks-neon-remote-storage-must-match-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.runtime.initContainers",
		"message": "Neon pageserver must configure rclone for the pCloud S3 endpoint with path-style access",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_version(resource.document)
	releases := object.get(object.get(resource.document, "spec", {}), "releases", [])
	some release_index
	release := releases[release_index]
	object.get(release, "changes", null) != null

	violation := {
		"policy": "kubeblocks-component-version-must-not-retain-changes",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.releases[%d].changes", [release_index]),
		"message": "ComponentVersion releases must not retain the forbidden changes field",
	}
}

violations contains violation if {
	kubeblocks_scope
	role := required_kubeblocks_component_version_roles[_]
	not kubeblocks_component_version_role_exists(role)

	violation := {
		"policy": "kubeblocks-component-version-roles-must-exist",
		"resource": "apps.kubeblocks.io/ComponentVersion//",
		"path": "metadata.name",
		"message": sprintf("required ComponentVersion role %s is missing", [role]),
	}
}

violations contains violation if {
	kubeblocks_scope
	role := required_kubeblocks_component_definition_roles[_]
	not kubeblocks_component_definition_role_exists(role)

	violation := {
		"policy": "kubeblocks-component-definition-roles-must-exist",
		"resource": "apps.kubeblocks.io/ComponentDefinition//",
		"path": "metadata.name",
		"message": sprintf("required ComponentDefinition role %s is missing", [role]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	role := required_kubeblocks_component_definition_roles[_]
	kubeblocks_component_definition_role(resource.document, role)
	not kubeblocks_runtime_security_context_present(resource.document)

	violation := {
		"policy": "kubeblocks-component-definition-must-have-security-context",
		"resource": resource_ref(resource.document),
		"path": "spec.runtime.securityContext",
		"message": sprintf("%s ComponentDefinition must set the runtime pod security context", [role]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	container := object.get(object.get(resource.document, "spec", {}), "runtime", {}).containers[_]
	env := object.get(container, "env", [])[_]
	credential_env_name := required_kubeblocks_s3_credential_env_names[_]
	object.get(env, "name", "") == credential_env_name
	not kubeblocks_credential_env_matches(env, credential_env_name)

	violation := {
		"policy": "kubeblocks-s3-credentials-must-use-secret-key-ref",
		"resource": resource_ref(resource.document),
		"path": "spec.runtime.containers[*].env",
		"message": sprintf("%s must use the %s Secret key from %s", [credential_env_name, kubeblocks_s3_credential_secret_keys[credential_env_name], kubeblocks_s3_secret_name]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	container := object.get(object.get(resource.document, "spec", {}), "runtime", {}).initContainers[_]
	env := object.get(container, "env", [])[_]
	credential_env_name := required_kubeblocks_s3_credential_env_names[_]
	object.get(env, "name", "") == credential_env_name
	not kubeblocks_credential_env_matches(env, credential_env_name)

	violation := {
		"policy": "kubeblocks-s3-credentials-must-use-secret-key-ref",
		"resource": resource_ref(resource.document),
		"path": "spec.runtime.initContainers[*].env",
		"message": sprintf("%s must use the %s Secret key from %s", [credential_env_name, kubeblocks_s3_credential_secret_keys[credential_env_name], kubeblocks_s3_secret_name]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	kubeblocks_component_definition_role(resource.document, "pageserver")
	credential_env_name := required_kubeblocks_s3_credential_env_names[_]
	not kubeblocks_credential_secret_ref_present(resource.document, credential_env_name)

	violation := {
		"policy": "kubeblocks-s3-credentials-must-use-secret-key-ref",
		"resource": resource_ref(resource.document),
		"path": "spec.runtime.containers[*].env / spec.runtime.initContainers[*].env",
		"message": sprintf("%s must use the %s Secret key from %s", [credential_env_name, kubeblocks_s3_credential_secret_keys[credential_env_name], kubeblocks_s3_secret_name]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_external_secret(resource.document)
	resource_name(resource.document) == "neon-s3-credentials"
	not kubeblocks_external_secret_has_credential(resource.document, "AWS_ACCESS_KEY_ID")

	violation := {
		"policy": "kubeblocks-s3-external-secret-must-provide-credentials",
		"resource": resource_ref(resource.document),
		"path": "spec.data",
		"message": "the Neon S3 ExternalSecret must provide AWS_ACCESS_KEY_ID",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_external_secret(resource.document)
	resource_name(resource.document) == kubeblocks_s3_secret_name
	credential_name := required_kubeblocks_s3_credentials[_]
	not kubeblocks_external_secret_has_expected_remote_ref(resource.document, credential_name)

	violation := {
		"policy": "kubeblocks-s3-external-secret-must-use-expected-remote-ref",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.data[%s].remoteRef.key", [credential_name]),
		"message": sprintf("%s must read from remoteRef.key %s", [credential_name, kubeblocks_s3_remote_keys[credential_name]]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_external_secret(resource.document)
	resource_name(resource.document) == kubeblocks_s3_secret_name
	not kubeblocks_external_secret_targets_credential_secret(resource.document)

	violation := {
		"policy": "kubeblocks-s3-external-secret-must-target-credential-secret",
		"resource": resource_ref(resource.document),
		"path": "spec.target.name",
		"message": sprintf("the ExternalSecret must target the %s Secret consumed by ComponentDefinitions", [kubeblocks_s3_secret_name]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_external_secret(resource.document)
	resource_name(resource.document) == "neon-s3-credentials"
	not kubeblocks_external_secret_has_credential(resource.document, "AWS_SECRET_ACCESS_KEY")

	violation := {
		"policy": "kubeblocks-s3-external-secret-must-provide-credentials",
		"resource": resource_ref(resource.document),
		"path": "spec.data",
		"message": "the Neon S3 ExternalSecret must provide AWS_SECRET_ACCESS_KEY",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	object.get(object.get(resource.document, "spec", {}), "terminationPolicy", "") == "WipeOut"

	violation := {
		"policy": "kubeblocks-cluster-must-not-use-wipeout",
		"resource": resource_ref(resource.document),
		"path": "spec.terminationPolicy",
		"message": "KubeBlocks clusters must not use destructive WipeOut termination",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	spec := object.get(resource.document, "spec", {})
	object.get(spec, "clusterDef", "") != "neon"

	violation := {
		"policy": "kubeblocks-cluster-must-use-cluster-def",
		"resource": resource_ref(resource.document),
		"path": "spec.clusterDef",
		"message": "the Neon Cluster must use the clusterDef field",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	spec := object.get(resource.document, "spec", {})
	object.get(spec, "clusterDefinitionRef", null) != null

	violation := {
		"policy": "kubeblocks-cluster-must-use-cluster-def",
		"resource": resource_ref(resource.document),
		"path": "spec.clusterDefinitionRef",
		"message": "the deprecated clusterDefinitionRef field must not be used",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	object.get(object.get(resource.document, "spec", {}), "topology", "") != "default"

	violation := {
		"policy": "kubeblocks-cluster-must-use-default-topology",
		"resource": resource_ref(resource.document),
		"path": "spec.topology",
		"message": "the Neon Cluster must use the default topology",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	object.get(object.get(resource.document, "spec", {}), "terminationPolicy", "") != "Delete"

	violation := {
		"policy": "kubeblocks-cluster-must-use-delete-termination-policy",
		"resource": resource_ref(resource.document),
		"path": "spec.terminationPolicy",
		"message": "the Neon Cluster must use Delete termination",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	role := required_kubeblocks_component_version_roles[_]
	not kubeblocks_cluster_component_exists(resource.document, role)

	violation := {
		"policy": "kubeblocks-cluster-component-roles-must-exist",
		"resource": resource_ref(resource.document),
		"path": "spec.componentSpecs",
		"message": sprintf("required Neon component role %s is missing", [role]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	role := required_kubeblocks_component_version_roles[_]
	component := kubeblocks_cluster_component(resource.document, role)
	not kubeblocks_cluster_component_definition_matches(component, role)

	violation := {
		"policy": "kubeblocks-cluster-component-definition-wiring",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.componentSpecs[%s].componentDef", [role]),
		"message": sprintf("%s componentDef must reference a ComponentDefinition with serviceKind neon-%s", [role, role]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	role := required_kubeblocks_component_version_roles[_]
	component := kubeblocks_cluster_component(resource.document, role)
	expected := kubeblocks_expected_replicas[role]
	object.get(component, "replicas", null) != expected

	violation := {
		"policy": "kubeblocks-component-must-match-replicas",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.componentSpecs[%s].replicas", [role]),
		"message": sprintf("%s must run %d replicas", [role, expected]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	role := required_kubeblocks_component_version_roles[_]
	component := kubeblocks_cluster_component(resource.document, role)
	object.get(component, "resources", {}) != kubeblocks_expected_resources

	violation := {
		"policy": "kubeblocks-component-must-match-resources",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.componentSpecs[%s].resources", [role]),
		"message": sprintf("%s must retain the declared resource requests and limits", [role]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	role := {"compute", "pageserver", "safekeeper"}[_]
	component := kubeblocks_cluster_component(resource.document, role)
	not kubeblocks_data_volume_matches(component, role)

	violation := {
		"policy": "kubeblocks-component-must-use-data-volume",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.componentSpecs[%s].volumeClaimTemplates", [role]),
		"message": sprintf("%s must use its declared rook-ceph-block data volume", [role]),
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	component := kubeblocks_cluster_component(resource.document, "broker")
	count(object.get(component, "volumeClaimTemplates", [])) != 0

	violation := {
		"policy": "kubeblocks-component-must-use-data-volume",
		"resource": resource_ref(resource.document),
		"path": "spec.componentSpecs[broker].volumeClaimTemplates",
		"message": "neon-broker must not declare a data volume",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	spec := object.get(resource.document, "spec", {})
	node_selector := object.get(object.get(spec, "schedulingPolicy", {}), "nodeSelector", {})
	object.get(node_selector, "kubernetes.io/arch", "") != "amd64"

	violation := {
		"policy": "kubeblocks-cluster-must-schedule-on-amd64",
		"resource": resource_ref(resource.document),
		"path": "spec.schedulingPolicy.nodeSelector.kubernetes.io/arch",
		"message": "all Neon components must be scheduled on amd64 nodes",
	}
}

violations contains violation if {
	kubeblocks_scope
	resource := input.resources[_]
	kubeblocks_cluster(resource.document)
	role := required_kubeblocks_component_version_roles[_]
	component := kubeblocks_cluster_component(resource.document, role)
	object.get(component, "schedulingPolicy", null) != null

	violation := {
		"policy": "kubeblocks-component-must-not-override-scheduling",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.componentSpecs[%s].schedulingPolicy", [role]),
		"message": sprintf("%s must inherit the cluster scheduling policy", [role]),
	}
}

kubeblocks_scope if {
	object.get(input.context, "policyScope", "") == "kubeblocks"
}

kubeblocks_component_version(document) if {
	object.get(document, "apiVersion", "") == "apps.kubeblocks.io/v1"
	object.get(document, "kind", "") == "ComponentVersion"
}

kubeblocks_component_definition(document) if {
	object.get(document, "apiVersion", "") == "apps.kubeblocks.io/v1"
	object.get(document, "kind", "") == "ComponentDefinition"
}

kubeblocks_cluster(document) if {
	object.get(document, "apiVersion", "") == "apps.kubeblocks.io/v1"
	object.get(document, "kind", "") == "Cluster"
}

kubeblocks_external_secret(document) if {
	object.get(document, "apiVersion", "") == "external-secrets.io/v1"
	object.get(document, "kind", "") == "ExternalSecret"
}

kubeblocks_neon_script_config(document) if {
	object.get(document, "kind", "") == "ConfigMap"
	resource_name(document) == "neon-scripts-template"
}

kubeblocks_neon_rclone_runtime_contract(document) if {
	runtime := object.get(object.get(document, "spec", {}), "runtime", {})
	container := object.get(runtime, "initContainers", [])[_]
	object.get(container, "name", "") == "create-neon-s3-bucket"
	kubeblocks_env_value_present(container, "RCLONE_CONFIG_NEON_TYPE", "s3")
	kubeblocks_env_value_present(container, "RCLONE_CONFIG_NEON_PROVIDER", "Other")
	kubeblocks_env_value_present(container, "RCLONE_CONFIG_NEON_ENDPOINT", "http://gateway.pcloud-s3.svc.cluster.local:8080")
	kubeblocks_env_value_present(container, "RCLONE_CONFIG_NEON_REGION", "us-east-1")
	kubeblocks_env_value_present(container, "RCLONE_CONFIG_NEON_FORCE_PATH_STYLE", "true")
}

kubeblocks_env_value_present(container, expected_name, expected_value) if {
	env := object.get(container, "env", [])[_]
	object.get(env, "name", "") == expected_name
	object.get(env, "value", "") == expected_value
}

kubeblocks_component_version_role_exists(role) if {
	resource := input.resources[_]
	kubeblocks_component_version(resource.document)
	kubeblocks_component_version_role(resource.document, role)
}

kubeblocks_component_definition_role_exists(role) if {
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	kubeblocks_component_definition_role(resource.document, role)
}

kubeblocks_runtime_security_context_present(document) if {
	runtime := object.get(object.get(document, "spec", {}), "runtime", {})
	security_context := object.get(runtime, "securityContext", {})
	object.get(security_context, "fsGroup", null) == 996
	object.get(security_context, "fsGroupChangePolicy", "") == "OnRootMismatch"
}

kubeblocks_credential_secret_ref_present(document, credential_env_name) if {
	runtime := object.get(object.get(document, "spec", {}), "runtime", {})
	container := object.get(runtime, "containers", [])[ _ ]
	env := object.get(container, "env", [])[ _ ]
	object.get(env, "name", "") == credential_env_name
	kubeblocks_credential_env_matches(env, credential_env_name)
}

kubeblocks_credential_secret_ref_present(document, credential_env_name) if {
	runtime := object.get(object.get(document, "spec", {}), "runtime", {})
	container := object.get(runtime, "initContainers", [])[ _ ]
	env := object.get(container, "env", [])[ _ ]
	object.get(env, "name", "") == credential_env_name
	kubeblocks_credential_env_matches(env, credential_env_name)
}

kubeblocks_credential_env_matches(env, credential_env_name) if {
	secret_key_ref := object.get(object.get(env, "valueFrom", {}), "secretKeyRef", {})
	object.get(secret_key_ref, "name", "") == kubeblocks_s3_secret_name
	object.get(secret_key_ref, "key", "") == kubeblocks_s3_credential_secret_keys[credential_env_name]
}

kubeblocks_external_secret_has_credential(document, credential_name) if {
	entry := object.get(object.get(document, "spec", {}), "data", [])[ _ ]
	object.get(entry, "secretKey", "") == credential_name
}

kubeblocks_external_secret_has_expected_remote_ref(document, credential_name) if {
	entry := object.get(object.get(document, "spec", {}), "data", [])[ _ ]
	object.get(entry, "secretKey", "") == credential_name
	remote_ref := object.get(entry, "remoteRef", {})
	object.get(remote_ref, "key", "") == kubeblocks_s3_remote_keys[credential_name]
}

kubeblocks_external_secret_targets_credential_secret(document) if {
	target := object.get(object.get(document, "spec", {}), "target", {})
	object.get(target, "name", "") == kubeblocks_s3_secret_name
}

kubeblocks_cluster_component_exists(document, role) if {
	component := kubeblocks_cluster_component(document, role)
	component != null
}

kubeblocks_cluster_component(document, role) := component if {
	components := object.get(object.get(document, "spec", {}), "componentSpecs", [])
	component := components[_]
	regex.match(sprintf("^neon-%s$", [role]), object.get(component, "name", ""))
}

kubeblocks_cluster_component_definition_matches(component, role) if {
	component_definition_name := object.get(component, "componentDef", "")
	resource := input.resources[_]
	kubeblocks_component_definition(resource.document)
	resource_name(resource.document) == component_definition_name
	kubeblocks_component_definition_role(resource.document, role)
}

kubeblocks_component_version_role(document, role) if {
	regex.match(sprintf("^neon-%s(-|$)", [role]), resource_name(document))
}

kubeblocks_component_definition_role(document, role) if {
	spec := object.get(document, "spec", {})
	object.get(spec, "serviceKind", "") == sprintf("neon-%s", [role])
}

kubeblocks_data_volume_matches(component, role) if {
	claims := object.get(component, "volumeClaimTemplates", [])
	count(claims) == 1
	claim := claims[0]
	object.get(claim, "name", "") == "data"
	claim_spec := object.get(claim, "spec", {})
	object.get(claim_spec, "accessModes", []) == ["ReadWriteOnce"]
	object.get(claim_spec, "storageClassName", "") == "rook-ceph-block"
	storage := object.get(object.get(object.get(claim_spec, "resources", {}), "requests", {}), "storage", "")
	storage == kubeblocks_expected_storage[role]
}
