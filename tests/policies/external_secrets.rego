package manifest_policy

import rego.v1

required_external_secrets := [
	{"name": "rclone-s3-credentials", "namespace": "pcloud-s3"},
	{"name": "neon-s3-credentials", "namespace": "database"},
	{"name": "feed-reader-storage", "namespace": "app"},
]

violations contains violation if {
	external_secrets_required_scope
	not cluster_secret_store_exists

	violation := {
		"policy": "cluster-secret-store-must-exist",
		"resource": "external-secrets.io/ClusterSecretStore/external-secrets/1password-sdk",
		"path": "metadata.name",
		"message": "required ClusterSecretStore external-secrets/1password-sdk is missing",
	}
}

violations contains violation if {
	external_secrets_required_scope
	required := required_external_secrets[_]
	not external_secret_exists(required.name, required.namespace)

	violation := {
		"policy": "external-secret-must-include-required-resources",
		"resource": sprintf("external-secrets.io/ExternalSecret/%s/%s", [required.namespace, required.name]),
		"path": "metadata.name",
		"message": sprintf("required ExternalSecret %s/%s is missing", [required.namespace, required.name]),
	}
}

violations contains violation if {
	resource := input.resources[_]
	external_secrets_scope(resource)
	cluster_secret_store(resource.document)
	cache := secret_store_cache(resource.document)
	object.get(cache, "ttl", "") != "30m"

	violation := {
		"policy": "cluster-secret-store-must-configure-cache",
		"resource": resource_ref(resource.document),
		"path": "spec.provider.onepasswordSDK.cache.ttl",
		"message": "1password-sdk cache ttl must be 30m",
	}
}

violations contains violation if {
	resource := input.resources[_]
	external_secrets_scope(resource)
	cluster_secret_store(resource.document)
	cache := secret_store_cache(resource.document)
	object.get(cache, "maxSize", 0) != 100

	violation := {
		"policy": "cluster-secret-store-must-configure-cache",
		"resource": resource_ref(resource.document),
		"path": "spec.provider.onepasswordSDK.cache.maxSize",
		"message": "1password-sdk cache maxSize must be 100",
	}
}

violations contains violation if {
	resource := input.resources[_]
	external_secrets_scope(resource)
	external_secret(resource.document)
	interval := refresh_interval(resource.document)
	not valid_refresh_interval(interval)

	violation := {
		"policy": "external-secret-refresh-interval-must-be-valid",
		"resource": resource_ref(resource.document),
		"path": "spec.refreshInterval",
		"message": sprintf("ExternalSecret %s has malformed refreshInterval %s", [resource_name(resource.document), interval]),
	}
}

violations contains violation if {
	resource := input.resources[_]
	external_secrets_scope(resource)
	external_secret(resource.document)
	interval := refresh_interval(resource.document)
	valid_refresh_interval(interval)
	refresh_interval_minutes(interval) < 720

	violation := {
		"policy": "external-secret-refresh-interval-must-be-at-least-12h",
		"resource": resource_ref(resource.document),
		"path": "spec.refreshInterval",
		"message": sprintf("ExternalSecret %s refreshInterval must be at least 12h", [resource_name(resource.document)]),
	}
}

violations contains violation if {
	resource := input.resources[_]
	external_secrets_scope(resource)
	external_secret(resource.document)
	interval := refresh_interval(resource.document)
	valid_refresh_interval(interval)
	other := input.resources[_]
	other != resource
	external_secrets_scope(other)
	external_secret(other.document)
	refresh_interval(other.document) == interval

	violation := {
		"policy": "external-secret-refresh-interval-must-be-unique",
		"resource": resource_ref(resource.document),
		"path": "spec.refreshInterval",
		"message": sprintf("ExternalSecret %s refreshInterval %s must be unique", [resource_name(resource.document), interval]),
	}
}

external_secrets_scope(_) if {
	object.get(input.context, "policyScope", "") == "external-secrets"
}

external_secrets_scope(resource) if {
	regex.match("(^|/)clusters/home/configs/external-secrets/", resource.source)
}

external_secrets_required_scope if {
	object.get(input.context, "policyScope", "") == "external-secrets"
}

cluster_secret_store(document) if {
	object.get(document, "kind", "") == "ClusterSecretStore"
	resource_name(document) == "1password-sdk"
}

external_secret(document) if {
	object.get(document, "kind", "") == "ExternalSecret"
}

external_secret_exists(name, namespace) if {
	resource := input.resources[_]
	external_secrets_scope(resource)
	external_secret(resource.document)
	resource_name(resource.document) == name
	resource_namespace(resource.document) == namespace
}

cluster_secret_store_exists if {
	resource := input.resources[_]
	external_secrets_scope(resource)
	cluster_secret_store(resource.document)
}

secret_store_cache(document) := object.get(
	object.get(
		object.get(
			object.get(document, "spec", {}),
			"provider",
			{},
		),
		"onepasswordSDK",
		{},
	),
	"cache",
	{},
)

refresh_interval(document) := object.get(object.get(document, "spec", {}), "refreshInterval", "")

valid_refresh_interval(interval) if {
	regex.match("^[0-9]+h([0-9]+m)?$", interval)
}

refresh_interval_minutes(interval) := total if {
	parts := split(interval, "h")
	hours := to_number(parts[0])
	minutes := refresh_interval_minutes_suffix(parts)
	total := (hours * 60) + minutes
}

refresh_interval_minutes_suffix(parts) := minutes if {
	count(parts) > 1
	parts[1] != ""
	minutes := to_number(trim_suffix(parts[1], "m"))
} else := 0 if {
	count(parts) <= 1
} else := 0 if {
	count(parts) > 1
	parts[1] == ""
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
