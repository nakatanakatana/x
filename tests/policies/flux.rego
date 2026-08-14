package manifest_policy

import rego.v1

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/controllers/kubeblocks.yaml", "kubeblocks")
	not flux_depends_on(resource.document, "kubeblocks-crds", "flux-system")

	violation := {
		"policy": "flux-kubeblocks-must-depend-on-crds",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.dependsOn",
		"message": "kubeblocks must depend on kubeblocks-crds in flux-system",
	}
}

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/controllers/kubeblocks.yaml", "kubeblocks")
	object.get(object.get(resource.document, "spec", {}), "wait", false) != true

	violation := {
		"policy": "flux-kubeblocks-must-wait",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.wait",
		"message": "kubeblocks must wait for applied resources to become ready",
	}
}

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/controllers/kubeblocks.yaml", "kubeblocks")
	object.get(object.get(resource.document, "spec", {}), "timeout", "") == ""

	violation := {
		"policy": "flux-kubeblocks-must-have-timeout",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.timeout",
		"message": "kubeblocks must define a bounded reconciliation timeout",
	}
}

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/controllers/kubeblocks-crds.yaml", "kubeblocks-crds")
	object.get(object.get(resource.document, "spec", {}), "wait", false) != true

	violation := {
		"policy": "flux-kubeblocks-crds-must-wait",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.wait",
		"message": "kubeblocks-crds must wait for applied resources to become ready",
	}
}

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/configs/_next.yaml", "cluster-controllers")
	not flux_depends_on(resource.document, "cluster-configs", "flux-system")

	violation := {
		"policy": "flux-cluster-controllers-must-depend-on-configs",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.dependsOn",
		"message": "cluster-controllers must depend on cluster-configs in flux-system",
	}
}

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/configs/_next.yaml", "cluster-controllers")
	not flux_health_check(resource.document, "kustomize.toolkit.fluxcd.io/v1", "Kustomization", "kubeblocks", "flux-system")

	violation := {
		"policy": "flux-cluster-controllers-must-health-check-kubeblocks",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.healthChecks",
		"message": "cluster-controllers must health-check Kustomization/kubeblocks in flux-system",
	}
}

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/controllers/_next.yaml", "cluster-resources")
	not flux_depends_on(resource.document, "cluster-controllers", "flux-system")

	violation := {
		"policy": "flux-cluster-resources-must-depend-on-controllers",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.dependsOn",
		"message": "cluster-resources must depend on cluster-controllers in flux-system",
	}
}

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/controllers/_next.yaml", "cluster-resources")
	not flux_health_check(resource.document, "litestream.mytools.nakatanakatana.app/v1alpha1", "Litestream", "feed-reader-db-debug", "app")

	violation := {
		"policy": "flux-cluster-resources-must-health-check-litestream",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.healthChecks",
		"message": "cluster-resources must health-check Litestream/feed-reader-db-debug in app",
	}
}

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/resources/_next.yaml", "cluster-vcluster")
	not flux_depends_on(resource.document, "cluster-resources", "flux-system")

	violation := {
		"policy": "flux-cluster-vcluster-must-depend-on-resources",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.dependsOn",
		"message": "cluster-vcluster must depend on cluster-resources in flux-system",
	}
}

violations contains violation if {
	resource := input.resources[_]
	flux_kustomization(resource, "clusters/home/controllers/litestream-controller.yaml", "litestream-controller")
	not flux_depends_on(resource.document, "cert-manager", "flux-system")

	violation := {
		"policy": "flux-litestream-controller-must-depend-on-cert-manager",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.dependsOn",
		"message": "litestream-controller must depend on cert-manager in flux-system",
	}
}

violations contains violation if {
	resource := input.resources[_]
	resource.source == "clusters/home/resources/vcluster-app-sync.yaml"
	object.get(resource.document, "kind", "") == "Kustomization"
	object.get(object.get(resource.document, "metadata", {}), "name", "") == "vcluster-app-sync"
	object.get(object.get(resource.document, "metadata", {}), "namespace", "") == "app"
	not flux_depends_on(resource.document, "cluster-resources", "flux-system")

	violation := {
		"policy": "flux-vcluster-app-sync-must-depend-on-cluster-resources",
		"resource": flux_resource_ref(resource.document),
		"path": "spec.dependsOn",
		"message": "vcluster-app-sync must depend on cluster-resources in flux-system",
	}
}

flux_kustomization(resource, source, name) if {
	resource.source == source
	document := resource.document
	object.get(document, "kind", "") == "Kustomization"
	metadata := object.get(document, "metadata", {})
	object.get(metadata, "name", "") == name
	object.get(metadata, "namespace", "") == "flux-system"
}

flux_depends_on(document, expected_name, expected_namespace) if {
	spec := object.get(document, "spec", {})
	depends_on := object.get(spec, "dependsOn", [])
	dependency := depends_on[_]
	object.get(dependency, "name", "") == expected_name
	object.get(dependency, "namespace", flux_resource_namespace(document)) == expected_namespace
}

flux_health_check(document, expected_api_version, expected_kind, expected_name, expected_namespace) if {
	spec := object.get(document, "spec", {})
	health_checks := object.get(spec, "healthChecks", [])
	health_check := health_checks[_]
	object.get(health_check, "apiVersion", "") == expected_api_version
	object.get(health_check, "kind", "") == expected_kind
	object.get(health_check, "name", "") == expected_name
	object.get(health_check, "namespace", "") == expected_namespace
}

flux_resource_ref(document) := sprintf("%s/%s/%s/%s", [
	flux_api_group(document),
	object.get(document, "kind", ""),
	flux_resource_namespace(document),
	flux_resource_name(document),
])

flux_api_group(document) := group if {
	api_version := object.get(document, "apiVersion", "")
	parts := split(api_version, "/")
	count(parts) == 2
	group := parts[0]
} else := "core" if {
	not contains(object.get(document, "apiVersion", ""), "/")
}

flux_resource_name(document) := object.get(object.get(document, "metadata", {}), "name", "")

flux_resource_namespace(document) := namespace if {
	namespace := object.get(object.get(document, "metadata", {}), "namespace", "")
	namespace != ""
} else := "default" if {
	object.get(object.get(document, "metadata", {}), "namespace", "") == ""
}
