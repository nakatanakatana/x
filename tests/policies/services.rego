package manifest_policy

import rego.v1

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_service(resource.document)
	object.get(object.get(resource.document, "spec", {}), "type", "ClusterIP") == "NodePort"

	violation := {
		"policy": "service-must-not-use-nodeport",
		"resource": resource_ref(resource.document),
		"path": "spec.type",
		"message": "pcloud-s3 gateway service must not use NodePort",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_service(resource.document)
	not pcloud_gateway_service_has_port(resource.document)

	violation := {
		"policy": "pcloud-gateway-service-must-expose-s3-port",
		"resource": resource_ref(resource.document),
		"path": "spec.ports",
		"message": "pcloud-s3 gateway service must expose port 8080",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_service(resource.document)
	selector := object.get(object.get(resource.document, "spec", {}), "selector", {})
	object.get(selector, "app", "") != "rclone-s3-gateway"

	violation := {
		"policy": "pcloud-gateway-service-must-select-gateway",
		"resource": resource_ref(resource.document),
		"path": "spec.selector.app",
		"message": "pcloud-s3 gateway service must select the rclone-s3-gateway workload",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_gateway_ingress(resource)

	violation := {
		"policy": "pcloud-gateway-must-not-render-ingress",
		"resource": resource_ref(resource.document),
		"path": "kind",
		"message": "pcloud-s3 gateway must remain internal and must not render an Ingress",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_service(resource.document)
	object.get(object.get(resource.document, "spec", {}), "type", "ClusterIP") == "LoadBalancer"

	violation := {
		"policy": "service-must-not-use-loadbalancer",
		"resource": resource_ref(resource.document),
		"path": "spec.type",
		"message": "pcloud-s3 gateway service must not use LoadBalancer",
	}
}

violations contains violation if {
	resource := input.resources[_]
	pcloud_scope(resource)
	pcloud_gateway_service(resource.document)
	object.get(object.get(resource.document, "spec", {}), "type", "ClusterIP") != "ClusterIP"

	violation := {
		"policy": "service-must-use-clusterip",
		"resource": resource_ref(resource.document),
		"path": "spec.type",
		"message": "pcloud-s3 gateway service must use ClusterIP",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_debug_workload_scope(resource)
	object.get(resource.document, "kind", "") == "Service"

	violation := {
		"policy": "litestream-debug-workload-must-not-expose-service",
		"resource": resource_ref(resource.document),
		"path": "kind",
		"message": "litestream debug workload must not render a Service",
	}
}

violations contains violation if {
	resource := input.resources[_]
	litestream_debug_workload_scope(resource)
	object.get(resource.document, "kind", "") == "Ingress"

	violation := {
		"policy": "litestream-debug-workload-must-not-expose-ingress",
		"resource": resource_ref(resource.document),
		"path": "kind",
		"message": "litestream debug workload must not render an Ingress",
	}
}

pcloud_gateway_service(document) if {
	object.get(document, "kind", "") == "Service"
	resource_name(document) == "gateway"
	resource_namespace(document) == "pcloud-s3"
}

pcloud_gateway_service_has_port(document) if {
	ports := object.get(object.get(document, "spec", {}), "ports", [])
	port := ports[_]
	object.get(port, "port", 0) == 8080
}

pcloud_scope(resource) if {
	object.get(input.context, "policyScope", "") == "pcloud-s3"
}

pcloud_scope(resource) if {
	pcloud_component_source(resource)
}

pcloud_component_source(resource) if {
	regex.match("^render:components/pcloud-s3(/|$)", resource.source)
}

pcloud_gateway_ingress(resource) if {
	pcloud_component_source(resource)
	object.get(resource.document, "kind", "") == "Ingress"
	resource_namespace(resource.document) == "pcloud-s3"
}

litestream_debug_workload_scope(resource) if {
	litestream_debug_workload_source(resource)
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
