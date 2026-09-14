package manifest_policy

import rego.v1

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
