package manifest_policy

import rego.v1

violations contains violation if {
	ceph_rgw_full_contract
	not ceph_rgw_storage_resource("CephObjectStore", "rook-ceph", "celld")

	violation := {
		"policy": "ceph-rgw-must-include-storage-resources",
		"resource": "ceph.rook.io/CephObjectStore/rook-ceph/celld",
		"path": "metadata.name",
		"message": "shared Ceph RGW config must include the CephObjectStore",
	}
}

violations contains violation if {
	ceph_rgw_full_contract
	not ceph_rgw_storage_resource("StorageClass", "", "celld-rgw")

	violation := {
		"policy": "ceph-rgw-must-include-storage-resources",
		"resource": "storage.k8s.io/StorageClass/default/celld-rgw",
		"path": "metadata.name",
		"message": "shared Ceph RGW config must include the celld-rgw StorageClass",
	}
}

violations contains violation if {
	resource := input.resources[_]
	ceph_rgw_object_store_resource(resource)
	not ceph_rgw_object_store_contract(resource.document)

	violation := {
		"policy": "ceph-rgw-must-preserve-replicated-storage",
		"resource": resource_ref(resource.document),
		"path": "spec",
		"message": "shared Ceph RGW must preserve data and use three-way host-replicated pools with three gateways",
	}
}

violations contains violation if {
	resource := input.resources[_]
	ceph_rgw_storage_class_resource(resource)
	not ceph_rgw_storage_class_contract(resource.document)

	violation := {
		"policy": "ceph-rgw-must-retain-bucket",
		"resource": resource_ref(resource.document),
		"path": "spec",
		"message": "shared Ceph RGW bucket provisioning must use the retained celld-rgw StorageClass contract",
	}
}

ceph_rgw_full_contract if {
	object.get(input.context, "policyScope", "") == "ceph-rgw"
	object.get(input.context, "fullContract", false) == true
}

ceph_rgw_storage_resource(kind, namespace, name) if {
	resource := input.resources[_]
	ceph_rgw_storage_source(resource)
	object.get(resource.document, "kind", "") == kind
	ceph_rgw_manifest_namespace(resource.document) == namespace
	resource_name(resource.document) == name
}

ceph_rgw_storage_source(resource) if {
	resource.source == "clusters/home/configs/ceph-rgw-celld.yaml"
}

ceph_rgw_storage_class_resource(resource) if {
	ceph_rgw_storage_source(resource)
	object.get(resource.document, "kind", "") == "StorageClass"
	ceph_rgw_manifest_namespace(resource.document) == ""
	resource_name(resource.document) == "celld-rgw"
}

ceph_rgw_object_store_resource(resource) if {
	ceph_rgw_storage_source(resource)
	object.get(resource.document, "kind", "") == "CephObjectStore"
	ceph_rgw_manifest_namespace(resource.document) == "rook-ceph"
	resource_name(resource.document) == "celld"
}

ceph_rgw_object_store_contract(document) if {
	spec := object.get(document, "spec", {})
	object.get(spec, "preservePoolsOnDelete", false) == true
	ceph_rgw_replicated_host_pool(object.get(spec, "metadataPool", {}))
	ceph_rgw_replicated_host_pool(object.get(spec, "dataPool", {}))
	gateway := object.get(spec, "gateway", {})
	object.get(gateway, "port", 0) == 80
	object.get(gateway, "instances", 0) == 3
}

ceph_rgw_storage_class_contract(document) if {
	object.get(document, "provisioner", "") == "rook-ceph.ceph.rook.io/bucket"
	parameters := object.get(document, "parameters", {})
	object.get(parameters, "objectStoreName", "") == "celld"
	object.get(parameters, "objectStoreNamespace", "") == "rook-ceph"
	object.get(parameters, "region", "") == "us-east-1"
	object.get(document, "reclaimPolicy", "") == "Retain"
}

ceph_rgw_replicated_host_pool(pool) if {
	object.get(pool, "failureDomain", "") == "host"
	object.get(object.get(pool, "replicated", {}), "size", 0) == 3
}

ceph_rgw_manifest_namespace(document) := namespace if {
	metadata := object.get(document, "metadata", {})
	namespace := object.get(metadata, "namespace", "")
}
