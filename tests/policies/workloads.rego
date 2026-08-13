package manifest_policy

import rego.v1

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	object.get(pcloud_pod_spec(resource.document), "automountServiceAccountToken", true) != false

	violation := {
		"policy": "workload-must-disable-service-account-token",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.automountServiceAccountToken",
		"message": "pcloud-s3 gateway deployment must disable automountServiceAccountToken",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	not pcloud_pod_security_contract(resource.document)

	violation := {
		"policy": "pcloud-gateway-must-use-pod-security-context",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.securityContext",
		"message": "pcloud-s3 gateway must use the approved uid, gid, fsGroup, and fsGroupChangePolicy",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	not pcloud_runtime_contract(resource.document)

	violation := {
		"policy": "pcloud-gateway-must-match-runtime-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.containers[0]",
		"message": "pcloud-s3 gateway must preserve the S3 endpoint, remote, listen address, and cache runtime contract",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	object.get(object.get(resource.document, "spec", {}), "replicas", 0) != 1

	violation := {
		"policy": "pcloud-gateway-must-run-single-replica",
		"resource": resource_ref(resource.document),
		"path": "spec.replicas",
		"message": "pcloud-s3 gateway deployment must run exactly one replica",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	strategy := object.get(object.get(resource.document, "spec", {}), "strategy", {})
	object.get(strategy, "type", "") != "Recreate"

	violation := {
		"policy": "pcloud-gateway-must-recreate",
		"resource": resource_ref(resource.document),
		"path": "spec.strategy.type",
		"message": "pcloud-s3 gateway deployment must use Recreate updates",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	not pcloud_cache_wiring(resource.document)

	violation := {
		"policy": "pcloud-gateway-must-wire-cache",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec",
		"message": "pcloud-s3 gateway must mount the rclone-s3-cache claim at /cache",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	pod_security := object.get(pcloud_pod_spec(resource.document), "securityContext", {})
	object.get(pod_security, "runAsNonRoot", false) != true

	violation := {
		"policy": "workload-must-have-pod-security-context",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.securityContext.runAsNonRoot",
		"message": "pcloud-s3 gateway deployment must set runAsNonRoot=true",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_cache_pvc(resource.document)
	not pcloud_prune_protected(resource.document)

	violation := {
		"policy": "pcloud-cache-pvc-must-protect-from-prune",
		"resource": resource_ref(resource.document),
		"path": "metadata.annotations.kustomize.toolkit.fluxcd.io/prune",
		"message": "pcloud-s3 cache PVC must disable Flux prune",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	object.get(resource.document, "kind", "") == "Namespace"
	resource_name(resource.document) == "pcloud-s3"
	not pcloud_prune_protected(resource.document)

	violation := {
		"policy": "pcloud-namespace-must-protect-from-prune",
		"resource": resource_ref(resource.document),
		"path": "metadata.annotations.kustomize.toolkit.fluxcd.io/prune",
		"message": "pcloud-s3 namespace must disable Flux prune",
	}
}

violations contains violation if {
	pcloud_required_scope
	not pcloud_required_resource_exists("Namespace", "default", "pcloud-s3")

	violation := {
		"policy": "pcloud-must-include-resources",
		"resource": "core/Namespace//pcloud-s3",
		"path": "metadata.name",
		"message": "pCloud render must include the pcloud-s3 Namespace",
	}
}

violations contains violation if {
	pcloud_required_scope
	not pcloud_required_resource_exists("Deployment", "pcloud-s3", "rclone-s3-gateway")

	violation := {
		"policy": "pcloud-must-include-resources",
		"resource": "apps/Deployment/pcloud-s3/rclone-s3-gateway",
		"path": "metadata.name",
		"message": "pCloud render must include the rclone-s3-gateway Deployment",
	}
}

violations contains violation if {
	pcloud_required_scope
	not pcloud_required_resource_exists("Service", "pcloud-s3", "gateway")

	violation := {
		"policy": "pcloud-must-include-resources",
		"resource": "core/Service/pcloud-s3/gateway",
		"path": "metadata.name",
		"message": "pCloud render must include the gateway Service",
	}
}

violations contains violation if {
	pcloud_required_scope
	not pcloud_required_resource_exists("PersistentVolumeClaim", "pcloud-s3", "rclone-s3-cache")

	violation := {
		"policy": "pcloud-must-include-resources",
		"resource": "core/PersistentVolumeClaim/pcloud-s3/rclone-s3-cache",
		"path": "metadata.name",
		"message": "pCloud render must include the rclone-s3-cache PersistentVolumeClaim",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	pod_security := object.get(pcloud_pod_spec(resource.document), "securityContext", {})
	object.get(object.get(pod_security, "seccompProfile", {}), "type", "") != "RuntimeDefault"

	violation := {
		"policy": "workload-must-have-pod-security-context",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.securityContext.seccompProfile.type",
		"message": "pcloud-s3 gateway deployment must use RuntimeDefault seccomp",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	container_security := object.get(pcloud_container(resource.document), "securityContext", {})
	object.get(container_security, "allowPrivilegeEscalation", true) != false

	violation := {
		"policy": "workload-must-have-container-security-context",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation",
		"message": "pcloud-s3 gateway deployment must set allowPrivilegeEscalation=false",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	container_security := object.get(pcloud_container(resource.document), "securityContext", {})
	object.get(container_security, "readOnlyRootFilesystem", false) != true

	violation := {
		"policy": "workload-must-have-container-security-context",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem",
		"message": "pcloud-s3 gateway deployment must set readOnlyRootFilesystem=true",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_deployment(resource.document)
	container_security := object.get(pcloud_container(resource.document), "securityContext", {})
	not drop_all_capabilities(container_security)

	violation := {
		"policy": "workload-must-have-container-security-context",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.containers[0].securityContext.capabilities.drop",
		"message": "pcloud-s3 gateway deployment must drop all Linux capabilities",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_cache_pvc(resource.document)
	object.get(object.get(resource.document, "spec", {}), "storageClassName", "") != "rook-ceph-block"

	violation := {
		"policy": "persistent-volume-claim-must-match-storage-class",
		"resource": resource_ref(resource.document),
		"path": "spec.storageClassName",
		"message": "pcloud-s3 cache PVC must use storageClassName rook-ceph-block",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_cache_pvc(resource.document)
	storage := object.get(
		object.get(
			object.get(
				object.get(resource.document, "spec", {}),
				"resources",
				{},
			),
			"requests",
			{},
		),
		"storage",
		"",
	)
	storage != "50Gi"

	violation := {
		"policy": "persistent-volume-claim-must-match-storage-size",
		"resource": resource_ref(resource.document),
		"path": "spec.resources.requests.storage",
		"message": "pcloud-s3 cache PVC must request 50Gi of storage",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_cache_pvc(resource.document)
	not access_mode_present(resource.document, "ReadWriteOnce")

	violation := {
		"policy": "persistent-volume-claim-must-use-read-write-once",
		"resource": resource_ref(resource.document),
		"path": "spec.accessModes",
		"message": "pcloud-s3 cache PVC must use ReadWriteOnce access mode",
	}
}

violations contains violation if {
	litestream_controller_scope
	not litestream_controller_has_crd("litestreams.litestream.mytools.nakatanakatana.app")

	violation := {
		"policy": "litestream-controller-must-install-crds",
		"resource": "apiextensions.k8s.io/CustomResourceDefinition//litestreams.litestream.mytools.nakatanakatana.app",
		"path": "metadata.name",
		"message": "litestream controller render must include the Litestream CRD",
	}
}

violations contains violation if {
	litestream_controller_scope
	not litestream_controller_has_crd("litestreamreplicas.litestream.mytools.nakatanakatana.app")

	violation := {
		"policy": "litestream-controller-must-install-crds",
		"resource": "apiextensions.k8s.io/CustomResourceDefinition//litestreamreplicas.litestream.mytools.nakatanakatana.app",
		"path": "metadata.name",
		"message": "litestream controller render must include the LitestreamReplica CRD",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "Litestream"
	resource_name(resource.document) == "feed-reader-db-debug"
	object.get(
		object.get(
			object.get(resource.document, "spec", {}),
			"injection",
			{},
		),
		"targetContainer",
		"",
	) != "sqlite3"

	violation := {
		"policy": "litestream-debug-workload-must-match-injection-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.injection.targetContainer",
		"message": "Litestream injection must target the sqlite3 container",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "LitestreamReplica"
	resource_name(resource.document) == "feed-reader-db-debug-source"
	replica := object.get(object.get(resource.document, "spec", {}), "replica", {})
	object.get(replica, "replicate", null) != null

	violation := {
		"policy": "litestream-replica-must-not-enable-replication",
		"resource": resource_ref(resource.document),
		"path": "spec.replica.replicate",
		"message": "the feed-reader LitestreamReplica must remain a single-replica source",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "Litestream"
	resource_name(resource.document) == "feed-reader-db-debug"
	restore := litestream_restore(resource.document)
	replica_name := object.get(object.get(restore, "replicaRef", {}), "name", "")
	not litestream_replica_exists(resource_namespace(resource.document), replica_name)

	violation := {
		"policy": "litestream-restore-must-reference-replica",
		"resource": resource_ref(resource.document),
		"path": "spec.databases[0].restore.replicaRef.name",
		"message": "Litestream restore must reference an existing LitestreamReplica in the same namespace",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "LitestreamReplica"
	resource_name(resource.document) == "feed-reader-db-debug-source"
	resource_namespace(resource.document) != "app"

	violation := {
		"policy": "litestream-replica-must-match-storage-contract",
		"resource": resource_ref(resource.document),
		"path": "metadata.namespace",
		"message": "LitestreamReplica must remain in the app namespace",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "LitestreamReplica"
	resource_name(resource.document) == "feed-reader-db-debug-source"
	not litestream_replica_storage_contract(resource.document)

	violation := {
		"policy": "litestream-replica-must-match-storage-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.replica.s3",
		"message": "LitestreamReplica must preserve the feed-reader S3 endpoint, bucket, path, and Secret references",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_vcluster_source(resource)
	kind := object.get(resource.document, "kind", "")
	kind in {"Litestream", "LitestreamReplica"}

	violation := {
		"policy": "litestream-vcluster-must-not-contain-resources",
		"resource": resource_ref(resource.document),
		"path": "kind",
		"message": "vcluster render must not contain Litestream custom resources",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_vcluster_source(resource)
	object.get(resource.document, "kind", "") == "CustomResourceDefinition"
	resource_name(resource.document) in {
		"litestreams.litestream.mytools.nakatanakatana.app",
		"litestreamreplicas.litestream.mytools.nakatanakatana.app",
	}

	violation := {
		"policy": "litestream-vcluster-must-not-contain-resources",
		"resource": resource_ref(resource.document),
		"path": "metadata.name",
		"message": "vcluster render must not contain Litestream CRDs",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_vcluster_source(resource)
	litestream_vcluster_operational_resource(resource.document)

	violation := {
		"policy": "litestream-vcluster-must-not-contain-resources",
		"resource": resource_ref(resource.document),
		"path": "metadata.name",
		"message": "vcluster render must not contain Litestream controller or stale debug configuration resources",
	}
}

violations contains violation if {
	litestream_contract_scope
	not litestream_host_resource_exists("Litestream", "app", "feed-reader-db-debug")

	violation := {
		"policy": "litestream-host-must-include-resources",
		"resource": "litestream.mytools.nakatanakatana.app/Litestream/app/feed-reader-db-debug",
		"path": "metadata.name",
		"message": "host Litestream configuration must include feed-reader-db-debug",
	}
}

violations contains violation if {
	litestream_contract_scope
	not litestream_host_resource_exists("LitestreamReplica", "app", "feed-reader-db-debug-source")

	violation := {
		"policy": "litestream-host-must-include-resources",
		"resource": "litestream.mytools.nakatanakatana.app/LitestreamReplica/app/feed-reader-db-debug-source",
		"path": "metadata.name",
		"message": "host Litestream configuration must include feed-reader-db-debug-source",
	}
}

violations contains violation if {
	litestream_contract_scope
	not litestream_controller_resource_exists("Deployment", "litestream-controller-system", "litestream-controller-manager")

	violation := {
		"policy": "litestream-controller-must-include-resources",
		"resource": "apps/Deployment/litestream-controller-system/litestream-controller-manager",
		"path": "metadata.name",
		"message": "Litestream controller render must include its controller Deployment",
	}
}

violations contains violation if {
	litestream_contract_scope
	not litestream_debug_workload_resource_exists

	violation := {
		"policy": "litestream-debug-workload-must-include-resources",
		"resource": "apps/Deployment/feed-reader/feed-reader-db-debug",
		"path": "metadata.name",
		"message": "Litestream debug workload render must include feed-reader-db-debug",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "Litestream"
	resource_name(resource.document) == "feed-reader-db-debug"
	object.get(
		object.get(
			object.get(resource.document, "spec", {}),
			"injection",
			{},
		),
		"volume",
		"",
	) != "data"

	violation := {
		"policy": "litestream-debug-workload-must-match-injection-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.injection.volume",
		"message": "Litestream injection must target the data volume",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "Litestream"
	resource_name(resource.document) == "feed-reader-db-debug"
	restore := object.get(object.get(object.get(resource.document, "spec", {}), "databases", [])[0], "restore", {})
	object.get(object.get(restore, "replicaRef", {}), "name", "") != "feed-reader-db-debug-source"

	violation := {
		"policy": "litestream-debug-workload-must-match-injection-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.databases[0].restore.replicaRef.name",
		"message": "Litestream restore must reference feed-reader-db-debug-source",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "Litestream"
	resource_name(resource.document) == "feed-reader-db-debug"
	restore := object.get(object.get(object.get(resource.document, "spec", {}), "databases", [])[0], "restore", {})
	object.get(restore, "ifDatabaseExists", "") != "skip"

	violation := {
		"policy": "litestream-debug-workload-must-match-injection-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.databases[0].restore.ifDatabaseExists",
		"message": "Litestream restore must skip when the database already exists",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "Litestream"
	resource_name(resource.document) == "feed-reader-db-debug"
	restore := object.get(object.get(object.get(resource.document, "spec", {}), "databases", [])[0], "restore", {})
	object.get(restore, "ifReplicaMissing", "") != "fail"

	violation := {
		"policy": "litestream-debug-workload-must-match-injection-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.databases[0].restore.ifReplicaMissing",
		"message": "Litestream restore must fail when the replica is missing",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_debug_workload_resource(resource)
	annotations := litestream_annotations(resource.document)
	object.get(annotations, "litestream.mytools.nakatanakatana.app/inject", "") != "feed-reader-db-debug"

	violation := {
		"policy": "litestream-debug-workload-must-match-injection-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.template.metadata.annotations.litestream.mytools.nakatanakatana.app/inject",
		"message": "debug workload must request Litestream injection for feed-reader-db-debug",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_debug_workload_resource(resource)
	not litestream_debug_workload_container_contract(resource.document)

	violation := {
		"policy": "litestream-debug-workload-must-have-sqlite-container",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.containers",
		"message": "the Litestream debug workload must include a sqlite3 container",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_debug_workload_resource(resource)
	not litestream_debug_workload_data_volume_contract(resource.document)

	violation := {
		"policy": "litestream-debug-workload-must-use-data-emptydir",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.volumes / spec.template.spec.containers[*].volumeMounts",
		"message": "the Litestream debug workload must mount an emptyDir named data at /data",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_app_namespace_source(resource)
	resource.document.kind == "Namespace"
	resource_name(resource.document) == "app"
	labels := object.get(object.get(resource.document, "metadata", {}), "labels", {})
	object.get(labels, "litestream.mytools.nakatanakatana.app/injection", "") != "enabled"

	violation := {
		"policy": "litestream-app-namespace-must-enable-injection",
		"resource": resource_ref(resource.document),
		"path": "metadata.labels.litestream.mytools.nakatanakatana.app/injection",
		"message": "the app namespace must enable Litestream injection",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_debug_workload_resource(resource)
	annotations := litestream_annotations(resource.document)
	object.get(annotations, "litestream.mytools.nakatanakatana.app/target-container", "") != "sqlite3"

	violation := {
		"policy": "litestream-debug-workload-must-match-injection-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.template.metadata.annotations.litestream.mytools.nakatanakatana.app/target-container",
		"message": "debug workload must target the sqlite3 container for Litestream injection",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_debug_workload_resource(resource)
	annotations := litestream_annotations(resource.document)
	object.get(annotations, "litestream.mytools.nakatanakatana.app/volume", "") != "data"

	violation := {
		"policy": "litestream-debug-workload-must-match-injection-contract",
		"resource": resource_ref(resource.document),
		"path": "spec.template.metadata.annotations.litestream.mytools.nakatanakatana.app/volume",
		"message": "debug workload must target the data volume for Litestream injection",
	}
}

pcloud_gateway_deployment(document) if {
	object.get(document, "kind", "") == "Deployment"
	resource_name(document) == "rclone-s3-gateway"
	resource_namespace(document) == "pcloud-s3"
}

pcloud_cache_pvc(document) if {
	object.get(document, "kind", "") == "PersistentVolumeClaim"
	resource_name(document) == "rclone-s3-cache"
	resource_namespace(document) == "pcloud-s3"
}

pcloud_pod_spec(document) := object.get(object.get(object.get(document, "spec", {}), "template", {}), "spec", {})

pcloud_container(document) := object.get(pcloud_pod_spec(document), "containers", [])[0]

pcloud_cache_wiring(document) if {
	pod_spec := pcloud_pod_spec(document)
	container := pcloud_container(document)
	mount := object.get(container, "volumeMounts", [])[_]
	object.get(mount, "name", "") == "cache"
	object.get(mount, "mountPath", "") == "/cache"
	volume := object.get(pod_spec, "volumes", [])[_]
	object.get(volume, "name", "") == "cache"
	claim := object.get(object.get(volume, "persistentVolumeClaim", {}), "claimName", "")
	claim == "rclone-s3-cache"
}

pcloud_pod_security_contract(document) if {
	security := object.get(pcloud_pod_spec(document), "securityContext", {})
	object.get(security, "runAsNonRoot", false) == true
	object.get(security, "runAsUser", null) == 1009
	object.get(security, "runAsGroup", null) == 1009
	object.get(security, "fsGroup", null) == 1009
	object.get(security, "fsGroupChangePolicy", "") == "OnRootMismatch"
}

pcloud_runtime_contract(document) if {
	container := pcloud_container(document)
	args := object.get(container, "args", [])
	pcloud_arg_present(args, "serve")
	pcloud_arg_present(args, "s3")
	pcloud_arg_present(args, "pcloud:buckets")
	pcloud_arg_present(args, "--addr=:8080")
	pcloud_arg_present(args, "--log-level=NOTICE")
	pcloud_arg_present(args, "--vfs-cache-mode=writes")
	pcloud_arg_present(args, "--cache-dir=/cache")
	pcloud_arg_present(args, "--dir-cache-time=1h")
	pcloud_arg_present(args, "--poll-interval=5m")
	pcloud_arg_present(args, "--vfs-cache-max-size=45Gi")
	pcloud_arg_present(args, "--vfs-cache-min-free-space=2Gi")
	pcloud_arg_present(args, "--vfs-cache-max-age=24h")
	pcloud_arg_present(args, "--vfs-cache-poll-interval=1m")
	pcloud_arg_present(args, "--vfs-write-back=5s")
	pcloud_arg_present(args, "--transfers=2")
	pcloud_arg_present(args, "--buffer-size=16Mi")
	pcloud_env_value(container, "RCLONE_CONFIG_PCLOUD_TYPE", "pcloud")
	pcloud_env_value(container, "RCLONE_CONFIG_PCLOUD_HOSTNAME", "api.pcloud.com")
	pcloud_env_secret_ref(container, "RCLONE_CONFIG_PCLOUD_TOKEN", "rclone-s3-credentials", "PCLOUD_TOKEN")
	pcloud_env_secret_ref(container, "RCLONE_AUTH_KEY", "rclone-s3-credentials", "RCLONE_AUTH_KEY")
}

pcloud_arg_present(args, expected) if {
	args[_] == expected
}

pcloud_env_value(container, expected_name, expected_value) if {
	env := object.get(container, "env", [])[_]
	object.get(env, "name", "") == expected_name
	object.get(env, "value", "") == expected_value
}

pcloud_env_secret_ref(container, expected_name, expected_secret, expected_key) if {
	env := object.get(container, "env", [])[_]
	object.get(env, "name", "") == expected_name
	secret_key_ref := object.get(object.get(env, "valueFrom", {}), "secretKeyRef", {})
	object.get(secret_key_ref, "name", "") == expected_secret
	object.get(secret_key_ref, "key", "") == expected_key
}

litestream_debug_workload_container_contract(document) if {
	container := object.get(object.get(object.get(document, "spec", {}), "template", {}), "spec", {}).containers[_]
	object.get(container, "name", "") == "sqlite3"
}

litestream_debug_workload_data_volume_contract(document) if {
	pod_spec := object.get(object.get(object.get(document, "spec", {}), "template", {}), "spec", {})
	container := object.get(pod_spec, "containers", [])[_]
	mount := object.get(container, "volumeMounts", [])[_]
	object.get(mount, "name", "") == "data"
	object.get(mount, "mountPath", "") == "/data"
	volume := object.get(pod_spec, "volumes", [])[_]
	object.get(volume, "name", "") == "data"
	object.get(volume, "emptyDir", null) != null
}

litestream_app_namespace_source(resource) if {
	regex.match("(^|[:/])clusters/home/_system/namespaces/app\\.yaml$", resource.source)
}

pcloud_prune_protected(document) if {
	annotations := object.get(object.get(document, "metadata", {}), "annotations", {})
	object.get(annotations, "kustomize.toolkit.fluxcd.io/prune", "") == "disabled"
}

pcloud_required_scope if {
	full_contract_scope("pcloud-s3")
}

pcloud_required_scope if {
	some resource in input.resources
	pcloud_component_source(resource)
}

pcloud_required_resource_exists(kind, namespace, name) if {
	resource := input.resources[_]
	kind == "Namespace"
	object.get(resource.document, "kind", "") == kind
	resource_name(resource.document) == name
	resource_namespace(resource.document) == namespace
	pcloud_namespace_source(resource)
}

pcloud_required_resource_exists(kind, namespace, name) if {
	resource := input.resources[_]
	kind != "Namespace"
	object.get(resource.document, "kind", "") == kind
	resource_name(resource.document) == name
	resource_namespace(resource.document) == namespace
	pcloud_component_source(resource)
}

pcloud_namespace_source(resource) if {
	regex.match("(^|[:/])clusters/home/_system/namespaces/pcloud-s3\\.yaml$", resource.source)
}

litestream_restore(document) := object.get(
	object.get(object.get(document, "spec", {}), "databases", [])[0],
	"restore",
	{},
)

litestream_replica_exists(namespace, name) if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == "LitestreamReplica"
	resource_name(resource.document) == name
	resource_namespace(resource.document) == namespace
}

litestream_host_resource_exists(kind, namespace, name) if {
	resource := input.resources[_]
	litestream_host_source(resource)
	object.get(resource.document, "kind", "") == kind
	resource_name(resource.document) == name
	resource_namespace(resource.document) == namespace
}

litestream_controller_resource_exists(kind, namespace, name) if {
	resource := input.resources[_]
	litestream_controller_source(resource)
	object.get(resource.document, "kind", "") == kind
	resource_name(resource.document) == name
	resource_namespace(resource.document) == namespace
}

litestream_debug_workload_resource_exists if {
	resource := input.resources[_]
	litestream_debug_workload_resource(resource)
}

litestream_replica_storage_contract(document) if {
	replica := object.get(object.get(document, "spec", {}), "replica", {})
	s3 := object.get(replica, "s3", {})
	credentials := object.get(s3, "credentials", {})
	access_key_ref := object.get(object.get(credentials, "accessKeyID", {}), "secretKeyRef", {})
	access_secret_ref := object.get(object.get(credentials, "secretAccessKey", {}), "secretKeyRef", {})

	object.get(replica, "type", "") == "s3"
	object.get(s3, "endpoint", "") == "http://storage:8010"
	object.get(s3, "bucket", "") == "feed-reader"
	object.get(s3, "path", "") == "feed-reader.db"
	object.get(access_key_ref, "name", "") == "feed-reader-storage"
	object.get(access_key_ref, "key", "") == "access_key"
	object.get(access_secret_ref, "name", "") == "feed-reader-storage"
	object.get(access_secret_ref, "key", "") == "access_secret"
}

pcloud_scope(_) if {
	object.get(input.context, "policyScope", "") == "pcloud-s3"
}

full_contract_scope(scope) if {
	object.get(input.context, "policyScope", "") == scope
	object.get(input.context, "fullContract", false) == true
}

pcloud_scope(resource) if {
	regex.match("^render:components/pcloud-s3(/|$)", resource.source)
}

litestream_controller_scope if {
	some resource in input.resources
	litestream_controller_source(resource)
}

litestream_controller_has_crd(expected_name) if {
	some resource in input.resources
	litestream_controller_source(resource)
	object.get(resource.document, "kind", "") == "CustomResourceDefinition"
	resource_name(resource.document) == expected_name
}

litestream_host_source(resource) if {
	regex.match("(^|[:/])clusters/home/resources/litestream-debug\\.yaml$", resource.source)
}

litestream_debug_workload_resource(resource) if {
	object.get(resource.document, "kind", "") == "Deployment"
	resource_name(resource.document) == "feed-reader-db-debug"
	resource_namespace(resource.document) == "feed-reader"
	litestream_debug_workload_source(resource)
}

litestream_vcluster_source(resource) if {
	regex.match("^render:clusters/vcluster-app$", resource.source)
}

litestream_controller_source(resource) if {
	regex.match("^render:components/litestream-controller(/|$)", resource.source)
}

litestream_debug_workload_source(resource) if {
	regex.match("^render:clusters/vcluster-app/feed-reader-debug/workload(/|$)", resource.source)
}

litestream_contract_scope if {
	full_contract_scope("litestream")
}

litestream_contract_scope if {
	object.get(input.context, "policyScope", "") == "litestream"
	some resource in input.resources
	litestream_contract_anchor(resource)
}

litestream_contract_anchor(resource) if litestream_vcluster_source(resource)
litestream_contract_anchor(resource) if litestream_controller_source(resource)
litestream_contract_anchor(resource) if litestream_host_source(resource)

litestream_vcluster_operational_resource(document) if {
	object.get(document, "kind", "") == "Deployment"
	resource_name(document) in {"litestream-controller", "litestream-controller-manager"}
}

litestream_vcluster_operational_resource(document) if {
	object.get(document, "kind", "") == "ConfigMap"
	resource_name(document) in {"feed-reader-debug", "feed-reader-debug-config", "litestream-debug"}
}

litestream_vcluster_operational_resource(document) if {
	object.get(document, "kind", "") == "ConfigMap"
	contains(resource_name(document), "debug")
	object.get(object.get(document, "data", {}), "litestream.yml", null) != null
}

litestream_annotations(document) := object.get(
	object.get(
		object.get(
			object.get(document, "spec", {}),
			"template",
			{},
		),
		"metadata",
		{},
	),
	"annotations",
	{},
)

drop_all_capabilities(container_security) if {
	drops := object.get(object.get(container_security, "capabilities", {}), "drop", [])
	drops[_] == "ALL"
}

access_mode_present(document, expected) if {
	modes := object.get(object.get(document, "spec", {}), "accessModes", [])
	modes[_] == expected
}

resource_ref(document) := sprintf("%s/%s/%s/%s", [api_group(document), object.get(document, "kind", ""), resource_namespace(document), resource_name(document)])

api_group(document) := group if {
	api_version := object.get(document, "apiVersion", "")
	parts := split(api_version, "/")
	count(parts) == 2
	group := parts[0]
} else := "core" if {
	not contains(object.get(document, "apiVersion", ""), "/")
}

resource_name(document) := object.get(object.get(document, "metadata", {}), "name", "")

resource_namespace(document) := namespace if {
	namespace := object.get(object.get(document, "metadata", {}), "namespace", "")
	namespace != ""
} else := "default" if {
	object.get(object.get(document, "metadata", {}), "namespace", "") == ""
}
