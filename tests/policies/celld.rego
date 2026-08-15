package manifest_policy

import rego.v1

violations contains violation if {
	celld_full_contract
	not celld_runtime_resource("Namespace", "", "celld")

	violation := {
		"policy": "celld-must-include-runtime-resources",
		"resource": "core/Namespace/default/celld",
		"path": "metadata.name",
		"message": "celld render must include the celld Namespace",
	}
}

violations contains violation if {
	celld_full_contract
	not celld_runtime_resource("StatefulSet", "celld", "celld")

	violation := {
		"policy": "celld-must-include-runtime-resources",
		"resource": "apps/StatefulSet/celld/celld",
		"path": "metadata.name",
		"message": "celld render must include the celld StatefulSet",
	}
}

violations contains violation if {
	celld_full_contract
	not celld_runtime_resource("Service", "celld", "celld-internal")

	violation := {
		"policy": "celld-must-include-runtime-resources",
		"resource": "core/Service/celld/celld-internal",
		"path": "metadata.name",
		"message": "celld render must include the celld-internal Service",
	}
}

violations contains violation if {
	celld_full_contract
	not celld_runtime_resource("Service", "celld", "celld")

	violation := {
		"policy": "celld-must-include-runtime-resources",
		"resource": "core/Service/celld/celld",
		"path": "metadata.name",
		"message": "celld render must include the client Service",
	}
}

violations contains violation if {
	celld_full_contract
	not celld_runtime_resource("PodDisruptionBudget", "celld", "celld")

	violation := {
		"policy": "celld-must-include-runtime-resources",
		"resource": "policy/PodDisruptionBudget/celld/celld",
		"path": "metadata.name",
		"message": "celld render must include the celld PodDisruptionBudget",
	}
}

violations contains violation if {
	celld_full_contract
	not celld_runtime_resource("Ingress", "celld", "celld")

	violation := {
		"policy": "celld-must-include-runtime-resources",
		"resource": "networking.k8s.io/Ingress/celld/celld",
		"path": "metadata.name",
		"message": "celld render must include the celld Ingress",
	}
}

violations contains violation if {
	celld_full_contract
	not celld_storage_resource("CephObjectStore", "rook-ceph", "celld")

	violation := {
		"policy": "celld-must-include-storage-resources",
		"resource": "ceph.rook.io/CephObjectStore/rook-ceph/celld",
		"path": "metadata.name",
		"message": "celld storage config must include the CephObjectStore",
	}
}

violations contains violation if {
	celld_full_contract
	not celld_storage_resource("StorageClass", "", "celld-rgw")

	violation := {
		"policy": "celld-must-include-storage-resources",
		"resource": "storage.k8s.io/StorageClass/default/celld-rgw",
		"path": "metadata.name",
		"message": "celld storage config must include the celld-rgw StorageClass",
	}
}

violations contains violation if {
	celld_full_contract
	not celld_storage_resource("ObjectBucketClaim", "app", "celld-storage")

	violation := {
		"policy": "celld-must-include-storage-resources",
		"resource": "objectbucket.io/ObjectBucketClaim/app/celld-storage",
		"path": "metadata.name",
		"message": "celld storage config must include the celld-storage ObjectBucketClaim",
	}
}

violations contains violation if {
	celld_full_contract
	not celld_vcluster_resource_present

	violation := {
		"policy": "celld-must-include-vcluster-mapping",
		"resource": "kustomize.toolkit.fluxcd.io/Kustomization/flux-system/vcluster-app",
		"path": "spec.patches",
		"message": "celld contract must include the vcluster-app mapping resource",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_statefulset_resource(resource)
	not celld_statefulset_runtime_contract(resource.document)

	violation := {
		"policy": "celld-statefulset-must-match-runtime-contract",
		"resource": resource_ref(resource.document),
		"path": "spec",
		"message": "celld StatefulSet must preserve replicas, peer identity, bucket endpoint, listeners, and runtime environment",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_statefulset_resource(resource)
	not celld_statefulset_security_contract(resource.document)

	violation := {
		"policy": "celld-statefulset-must-use-restricted-security",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.securityContext",
		"message": "celld StatefulSet must use the restricted pod and container security contract",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_statefulset_resource(resource)
	not celld_statefulset_storage_contract(resource.document)

	violation := {
		"policy": "celld-statefulset-must-use-state-storage",
		"resource": resource_ref(resource.document),
		"path": "spec.volumeClaimTemplates",
		"message": "celld StatefulSet must mount the 10Gi rook-ceph-block state PVC and writable temporary directory",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_peer_service_resource(resource)
	not celld_peer_service_contract(resource.document)

	violation := {
		"policy": "celld-services-must-separate-client-and-peer-ports",
		"resource": resource_ref(resource.document),
		"path": "spec.ports",
		"message": "celld-internal must expose only peer port 8081 as a headless Service",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_client_service_resource(resource)
	not celld_client_service_contract(resource.document)

	violation := {
		"policy": "celld-services-must-separate-client-and-peer-ports",
		"resource": resource_ref(resource.document),
		"path": "spec.ports",
		"message": "celld client Service must expose only client port 8080",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_pdb_resource(resource)
	not celld_pdb_contract(resource.document)

	violation := {
		"policy": "celld-pdb-must-preserve-quorum",
		"resource": resource_ref(resource.document),
		"path": "spec.minAvailable",
		"message": "celld PodDisruptionBudget must keep two replicas available",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_ingress_resource(resource)
	not celld_ingress_contract(resource.document)

	violation := {
		"policy": "celld-ingress-must-be-tailnet-only",
		"resource": resource_ref(resource.document),
		"path": "spec",
		"message": "celld Ingress must use the Tailscale client endpoint on port 8080 only",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_unapproved_service_resource(resource)

	violation := {
		"policy": "celld-exposure-must-use-approved-resources",
		"resource": resource_ref(resource.document),
		"path": "metadata.name",
		"message": "celld namespace must not contain an unapproved Service",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_unapproved_ingress_resource(resource)

	violation := {
		"policy": "celld-exposure-must-use-approved-resources",
		"resource": resource_ref(resource.document),
		"path": "metadata.name",
		"message": "celld namespace must not contain an unapproved Ingress",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_unapproved_gateway_resource(resource)

	violation := {
		"policy": "celld-exposure-must-use-approved-resources",
		"resource": resource_ref(resource.document),
		"path": "metadata.name",
		"message": "celld namespace must not contain an HTTPRoute or Gateway",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_object_store_resource(resource)
	not celld_object_store_contract(resource.document)

	violation := {
		"policy": "celld-rgw-must-preserve-replicated-storage",
		"resource": resource_ref(resource.document),
		"path": "spec",
		"message": "celld RGW must preserve data and use three-way host-replicated pools with three gateways",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_storage_class_resource(resource)
	not celld_storage_class_contract(resource.document)

	violation := {
		"policy": "celld-rgw-must-retain-bucket",
		"resource": resource_ref(resource.document),
		"path": "spec",
		"message": "celld RGW bucket provisioning must use the retained celld-rgw StorageClass contract",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_obc_resource(resource)
	not celld_obc_contract(resource.document)

	violation := {
		"policy": "celld-rgw-must-retain-bucket",
		"resource": resource_ref(resource.document),
		"path": "spec",
		"message": "celld ObjectBucketClaim must provision the retained celld bucket",
	}
}

violations contains violation if {
	resource := input.resources[_]
	celld_vcluster_resource(resource)
	not celld_vcluster_mapping_contract(resource.document)

	violation := {
		"policy": "celld-vcluster-must-map-private-storage",
		"resource": resource_ref(resource.document),
		"path": "spec.patches",
		"message": "vcluster-app must map only the private celld RGW Service and generated Secret",
	}
}

celld_full_contract if {
	object.get(input.context, "policyScope", "") == "celld"
	object.get(input.context, "fullContract", false) == true
}

celld_runtime_resource(kind, namespace, name) if {
	resource := input.resources[_]
	celld_runtime_source(resource)
	object.get(resource.document, "kind", "") == kind
	celld_manifest_namespace(resource.document) == namespace
	resource_name(resource.document) == name
}

celld_storage_resource(kind, namespace, name) if {
	resource := input.resources[_]
	celld_storage_source(resource)
	object.get(resource.document, "kind", "") == kind
	celld_manifest_namespace(resource.document) == namespace
	resource_name(resource.document) == name
}

celld_vcluster_resource_present if {
	resource := input.resources[_]
	celld_vcluster_resource(resource)
}

celld_vcluster_resource(resource) if {
	celld_vcluster_source(resource)
	object.get(resource.document, "kind", "") == "Kustomization"
	resource_namespace(resource.document) == "flux-system"
	resource_name(resource.document) == "vcluster-app"
}

celld_runtime_source(resource) if {
	resource.source == "render:clusters/vcluster-app/celld"
}

celld_runtime_source(resource) if {
	resource.source == "render:clusters/vcluster-app"
	object.get(input.context, "policyScope", "") == "celld"
}

celld_storage_source(resource) if {
	resource.source == "clusters/home/configs/ceph-rgw-celld.yaml"
}

celld_vcluster_source(resource) if {
	resource.source == "clusters/home/resources/vcluster-app.yaml"
}

celld_statefulset_resource(resource) if {
	celld_runtime_source(resource)
	object.get(resource.document, "kind", "") == "StatefulSet"
	resource_namespace(resource.document) == "celld"
	resource_name(resource.document) == "celld"
}

celld_peer_service_resource(resource) if {
	celld_runtime_source(resource)
	object.get(resource.document, "kind", "") == "Service"
	resource_namespace(resource.document) == "celld"
	resource_name(resource.document) == "celld-internal"
}

celld_client_service_resource(resource) if {
	celld_runtime_source(resource)
	object.get(resource.document, "kind", "") == "Service"
	resource_namespace(resource.document) == "celld"
	resource_name(resource.document) == "celld"
}

celld_pdb_resource(resource) if {
	celld_runtime_source(resource)
	object.get(resource.document, "kind", "") == "PodDisruptionBudget"
	resource_namespace(resource.document) == "celld"
	resource_name(resource.document) == "celld"
}

celld_ingress_resource(resource) if {
	celld_runtime_source(resource)
	object.get(resource.document, "kind", "") == "Ingress"
	resource_namespace(resource.document) == "celld"
	resource_name(resource.document) == "celld"
}

celld_unapproved_service_resource(resource) if {
	celld_runtime_source(resource)
	object.get(resource.document, "kind", "") == "Service"
	resource_namespace(resource.document) == "celld"
	resource_name(resource.document) != "celld"
	resource_name(resource.document) != "celld-internal"
}

celld_unapproved_ingress_resource(resource) if {
	celld_runtime_source(resource)
	object.get(resource.document, "kind", "") == "Ingress"
	resource_namespace(resource.document) == "celld"
	resource_name(resource.document) != "celld"
}

celld_unapproved_gateway_resource(resource) if {
	celld_runtime_source(resource)
	kind := object.get(resource.document, "kind", "")
	kind in {"HTTPRoute", "Gateway"}
	resource_namespace(resource.document) == "celld"
}

celld_storage_class_resource(resource) if {
	celld_storage_source(resource)
	object.get(resource.document, "kind", "") == "StorageClass"
	celld_manifest_namespace(resource.document) == ""
	resource_name(resource.document) == "celld-rgw"
}

celld_obc_resource(resource) if {
	celld_storage_source(resource)
	object.get(resource.document, "kind", "") == "ObjectBucketClaim"
	celld_manifest_namespace(resource.document) == "app"
	resource_name(resource.document) == "celld-storage"
}

celld_object_store_resource(resource) if {
	celld_storage_source(resource)
	object.get(resource.document, "kind", "") == "CephObjectStore"
	celld_manifest_namespace(resource.document) == "rook-ceph"
	resource_name(resource.document) == "celld"
}

celld_statefulset_runtime_contract(document) if {
	spec := object.get(document, "spec", {})
	template := object.get(spec, "template", {})
	object.get(spec, "replicas", 0) == 3
	object.get(spec, "serviceName", "") == "celld-internal"
	container := celld_container(document)
	regex.match("^ghcr\\.io/denoland/celld@sha256:[0-9a-f]{64}$", object.get(container, "image", ""))
	object.get(container, "args", []) == [
		"--bucket",
		"s3://celld",
		"--endpoint",
		"http://rgw.celld.svc.cluster.local:80",
		"--region",
		"us-east-1",
		"--listen",
		"0.0.0.0:8080",
		"--internal-listen",
		"0.0.0.0:8081",
		"--advertise",
		"$(POD_NAME).celld-internal.celld.svc:8081",
	]
	celld_pod_name_environment(document)
	celld_secret_key_ref(document, "AWS_ACCESS_KEY_ID", "celld-storage", "AWS_ACCESS_KEY_ID")
	celld_secret_key_ref(document, "AWS_SECRET_ACCESS_KEY", "celld-storage", "AWS_SECRET_ACCESS_KEY")
	object.get(celld_environment(document, "CELLD_WATCH"), "value", "") == "/var/lib/celld/state"
	object.get(celld_environment(document, "CELLD_MAX_RSS_MB"), "value", "") == "768"
}

celld_statefulset_security_contract(document) if {
	pod_specification := pod_spec(document)
	pod_security := object.get(pod_spec(document), "securityContext", {})
	object.get(pod_specification, "automountServiceAccountToken", true) == false
	object.get(pod_specification, "hostNetwork", false) == false
	object.get(pod_specification, "hostPID", false) == false
	object.get(pod_security, "runAsNonRoot", false) == true
	object.get(pod_security, "runAsUser", 0) == 65532
	object.get(pod_security, "runAsGroup", 0) == 65532
	object.get(pod_security, "fsGroup", 0) == 65532
	object.get(pod_security, "fsGroupChangePolicy", "") == "OnRootMismatch"
	object.get(object.get(pod_security, "seccompProfile", {}), "type", "") == "RuntimeDefault"
	container_security := object.get(celld_container(document), "securityContext", {})
	object.get(container_security, "allowPrivilegeEscalation", true) == false
	object.get(container_security, "privileged", false) == false
	object.get(object.get(container_security, "capabilities", {}), "add", []) == []
	object.get(container_security, "readOnlyRootFilesystem", false) == true
	"ALL" in object.get(object.get(container_security, "capabilities", {}), "drop", [])
	resources := object.get(celld_container(document), "resources", {})
	object.get(resources, "limits", {}) == {"cpu": "1", "memory": "1Gi"}
	object.get(resources, "requests", {}) == {"cpu": "250m", "memory": "512Mi"}
	celld_probe_contract(celld_container(document), "livenessProbe")
	celld_probe_contract(celld_container(document), "readinessProbe")
	celld_anti_affinity_contract(document)
}

celld_statefulset_storage_contract(document) if {
	pod_specification := pod_spec(document)
	volume_mounts := object.get(celld_container(document), "volumeMounts", [])
	celld_volume_mount(volume_mounts, "/var/lib/celld", "data")
	celld_volume_mount(volume_mounts, "/tmp", "tmp")
	celld_empty_dir_volume(pod_specification, "tmp")
	template := object.get(document["spec"], "volumeClaimTemplates", [])[0]
	object.get(template["metadata"], "name", "") == "data"
	volume_spec := object.get(template, "spec", {})
	object.get(volume_spec, "storageClassName", "") == "rook-ceph-block"
	"ReadWriteOnce" in object.get(volume_spec, "accessModes", [])
	object.get(object.get(object.get(volume_spec, "resources", {}), "requests", {}), "storage", "") == "10Gi"
}

celld_peer_service_contract(document) if {
	spec := object.get(document, "spec", {})
	object.get(spec, "clusterIP", "") == "None"
	ports := object.get(spec, "ports", [])
	count(ports) == 1
	port := ports[0]
	object.get(port, "name", "") == "peer"
	object.get(port, "port", 0) == 8081
	object.get(port, "targetPort", "") == "peer"
	object.get(spec, "publishNotReadyAddresses", false) == true
	object.get(object.get(spec, "selector", {}), "app", "") == "celld"
}

celld_client_service_contract(document) if {
	spec := object.get(document, "spec", {})
	object.get(spec, "type", "ClusterIP") == "ClusterIP"
	ports := object.get(spec, "ports", [])
	count(ports) == 1
	port := ports[0]
	object.get(port, "name", "") == "client"
	object.get(port, "port", 0) == 8080
	object.get(port, "targetPort", "") == "client"
	object.get(object.get(spec, "selector", {}), "app", "") == "celld"
}

celld_pdb_contract(document) if {
	spec := object.get(document, "spec", {})
	object.get(spec, "minAvailable", 0) == 2
	object.get(object.get(spec, "selector", {})["matchLabels"], "app", "") == "celld"
}

celld_ingress_contract(document) if {
	spec := object.get(document, "spec", {})
	object.get(spec, "ingressClassName", "") == "tailscale"
	object.get(spec, "defaultBackend", null) == null
	annotations := object.get(document["metadata"], "annotations", {})
	object.get(annotations, "tailscale.com/hostname", "") == "celld"
	object.get(annotations, "tailscale.com/proxy-class", "") == "avoid-slow-nodes"
	rules := object.get(spec, "rules", [])
	count(rules) == 1
	tls := object.get(spec, "tls", [])
	count(tls) == 1
	object.get(tls[0], "hosts", []) == ["celld"]
	rule := rules[0]
	object.get(rule, "host", null) == null
	paths := object.get(object.get(rule, "http", {}), "paths", [])
	count(paths) == 1
	path := paths[0]
	object.get(path, "path", "") == "/"
	object.get(path, "pathType", "") == "Prefix"
	backend := object.get(path, "backend", {})
	service := object.get(backend, "service", {})
	object.get(service, "name", "") == "celld"
	object.get(object.get(service, "port", {}), "number", 0) == 8080
}

celld_object_store_contract(document) if {
	spec := object.get(document, "spec", {})
	object.get(spec, "preservePoolsOnDelete", false) == true
	celld_replicated_host_pool(object.get(spec, "metadataPool", {}))
	celld_replicated_host_pool(object.get(spec, "dataPool", {}))
	gateway := object.get(spec, "gateway", {})
	object.get(gateway, "port", 0) == 80
	object.get(gateway, "instances", 0) == 3
}

celld_storage_class_contract(document) if {
	object.get(document, "provisioner", "") == "rook-ceph.ceph.rook.io/bucket"
	parameters := object.get(document, "parameters", {})
	object.get(parameters, "objectStoreName", "") == "celld"
	object.get(parameters, "objectStoreNamespace", "") == "rook-ceph"
	object.get(parameters, "region", "") == "us-east-1"
	object.get(document, "reclaimPolicy", "") == "Retain"
}

celld_obc_contract(document) if {
	spec := object.get(document, "spec", {})
	object.get(spec, "bucketName", "") == "celld"
	object.get(spec, "storageClassName", "") == "celld-rgw"
}

celld_vcluster_mapping_contract(document) if {
	patches := object.get(object.get(document, "spec", {}), "patches", [])
	patch := patches[_]
	patch_text := object.get(patch, "patch", "")
	count(regex.find_all_string_submatch_n("(?m)^[ \\t]*- from: rook-ceph/rook-ceph-rgw-celld[ \\t]*\\n[ \\t]+to: celld/rgw[ \\t]*$", patch_text, -1)) == 1
	count(regex.find_all_string_submatch_n("(?m)^[ \\t]*- from: rook-ceph/rook-ceph-rgw-celld[ \\t]*$", patch_text, -1)) == 1
	count(regex.find_all_string_submatch_n("(?m)^[ \\t]+to: celld/rgw[ \\t]*$", patch_text, -1)) == 1
	count(regex.find_all_string_submatch_n("(?m)^[ \\t]*\"app/celld-storage\":", patch_text, -1)) == 1
	count(regex.find_all_string_submatch_n("(?m)^\\s*\"app/celld-storage\": \"celld/celld-storage\"\\s*$", patch_text, -1)) == 1
}

celld_replicated_host_pool(pool) if {
	object.get(pool, "failureDomain", "") == "host"
	object.get(object.get(pool, "replicated", {}), "size", 0) == 3
}

celld_manifest_namespace(document) := namespace if {
	metadata := object.get(document, "metadata", {})
	namespace := object.get(metadata, "namespace", "")
}

celld_container(document) := container if {
	containers := pod_spec_containers(document)
	count(containers) == 1
	container := containers[0]
}

celld_environment(document, name) := env if {
	container := celld_container(document)
	env := object.get(container, "env", [])[_]
	object.get(env, "name", "") == name
}

celld_secret_key_ref(document, env_name, secret_name, key_name) if {
	env := celld_environment(document, env_name)
	value_from := object.get(env, "valueFrom", {})
	secret_key_ref := object.get(value_from, "secretKeyRef", {})
	object.get(secret_key_ref, "name", "") == secret_name
	object.get(secret_key_ref, "key", "") == key_name
}

celld_pod_name_environment(document) if {
	env := celld_environment(document, "POD_NAME")
	field_ref := object.get(object.get(env, "valueFrom", {}), "fieldRef", {})
	object.get(field_ref, "fieldPath", "") == "metadata.name"
}

celld_probe_contract(container, field) if {
	probe := object.get(container, field, {})
	object.get(object.get(probe, "httpGet", {}), "path", "") == "/__celld/health"
	object.get(object.get(probe, "httpGet", {}), "port", "") == "client"
}

celld_anti_affinity_contract(document) if {
	affinity := object.get(pod_spec(document), "affinity", {})
	anti_affinity := object.get(affinity, "podAntiAffinity", {})
	terms := object.get(anti_affinity, "requiredDuringSchedulingIgnoredDuringExecution", [])
	count(terms) == 1
	term := terms[0]
	object.get(object.get(term, "labelSelector", {})["matchLabels"], "app", "") == "celld"
	object.get(term, "topologyKey", "") == "kubernetes.io/hostname"
}

celld_volume_mount(mounts, path, name) if {
	mount := mounts[_]
	object.get(mount, "mountPath", "") == path
	object.get(mount, "name", "") == name
}

celld_empty_dir_volume(pod_specification, name) if {
	volume := object.get(pod_specification, "volumes", [])[_]
	object.get(volume, "name", "") == name
	object.get(volume, "emptyDir", null) != null
}
