package manifest_policy

import rego.v1

violations contains violation if {
	common_policy_scope
	resource := input.resources[_]
	container := pod_spec_containers(resource.document)[index]
	image := object.get(container, "image", "")
	image != ""
	uses_latest_tag(image)

	violation := {
		"policy": "image-must-not-use-latest",
		"resource": resource_ref(resource.document),
		"path": sprintf("%s.containers[%d].image", [pod_spec_path(resource.document), index]),
		"message": "container image must not use the mutable latest tag",
	}
}

violations contains violation if {
	common_policy_scope
	resource := input.resources[_]
	container := pod_spec_init_containers(resource.document)[index]
	image := object.get(container, "image", "")
	image != ""
	uses_latest_tag(image)

	violation := {
		"policy": "image-must-not-use-latest",
		"resource": resource_ref(resource.document),
		"path": sprintf("%s.initContainers[%d].image", [pod_spec_path(resource.document), index]),
		"message": "container image must not use the mutable latest tag",
	}
}

violations contains violation if {
	common_policy_scope
	resource := input.resources[_]
	container := pod_spec_ephemeral_containers(resource.document)[index]
	image := object.get(container, "image", "")
	image != ""
	uses_latest_tag(image)

	violation := {
		"policy": "image-must-not-use-latest",
		"resource": resource_ref(resource.document),
		"path": sprintf("%s.ephemeralContainers[%d].image", [pod_spec_path(resource.document), index]),
		"message": "container image must not use the mutable latest tag",
	}
}

violations contains violation if {
	common_policy_scope
	resource := input.resources[_]
	container := pod_spec_ephemeral_containers(resource.document)[index]
	env := object.get(container, "env", [])[env_index]
	env_name := upper(object.get(env, "name", ""))
	credential_env_name(env_name)
	not credential_uses_secret_key_ref(env)

	violation := {
		"policy": "credential-must-use-secret-key-ref",
		"resource": resource_ref(resource.document),
		"path": sprintf("%s.ephemeralContainers[%d].env[%d]", [pod_spec_path(resource.document), index, env_index]),
		"message": sprintf("credential environment variable %s must use valueFrom.secretKeyRef", [object.get(env, "name", "")]),
	}
}

violations contains violation if {
	common_policy_scope
	resource := input.resources[_]
	container := pod_spec_containers(resource.document)[index]
	image := object.get(container, "image", "")
	image != ""
	not has_valid_sha256_digest(image)

	violation := {
		"policy": "image-must-be-digest-pinned",
		"resource": resource_ref(resource.document),
		"path": sprintf("%s.containers[%d].image", [pod_spec_path(resource.document), index]),
		"message": "container image must include a sha256 digest",
	}
}

violations contains violation if {
	common_policy_scope
	resource := input.resources[_]
	container := pod_spec_init_containers(resource.document)[index]
	image := object.get(container, "image", "")
	image != ""
	not has_valid_sha256_digest(image)

	violation := {
		"policy": "image-must-be-digest-pinned",
		"resource": resource_ref(resource.document),
		"path": sprintf("%s.initContainers[%d].image", [pod_spec_path(resource.document), index]),
		"message": "container image must include a sha256 digest",
	}
}

violations contains violation if {
	common_policy_scope
	resource := input.resources[_]
	container := pod_spec_ephemeral_containers(resource.document)[index]
	image := object.get(container, "image", "")
	image != ""
	not has_valid_sha256_digest(image)

	violation := {
		"policy": "image-must-be-digest-pinned",
		"resource": resource_ref(resource.document),
		"path": sprintf("%s.ephemeralContainers[%d].image", [pod_spec_path(resource.document), index]),
		"message": "container image must include a sha256 digest",
	}
}

violations contains violation if {
	common_policy_scope
	resource := input.resources[_]
	container := pod_spec_containers(resource.document)[index]
	env := object.get(container, "env", [])[env_index]
	env_name := upper(object.get(env, "name", ""))
	credential_env_name(env_name)
	not credential_uses_secret_key_ref(env)

	violation := {
		"policy": "credential-must-use-secret-key-ref",
		"resource": resource_ref(resource.document),
		"path": sprintf("%s.containers[%d].env[%d]", [pod_spec_path(resource.document), index, env_index]),
		"message": sprintf("credential environment variable %s must use valueFrom.secretKeyRef", [object.get(env, "name", "")]),
	}
}

violations contains violation if {
	common_policy_scope
	resource := input.resources[_]
	container := pod_spec_init_containers(resource.document)[index]
	env := object.get(container, "env", [])[env_index]
	env_name := upper(object.get(env, "name", ""))
	credential_env_name(env_name)
	not credential_uses_secret_key_ref(env)

	violation := {
		"policy": "credential-must-use-secret-key-ref",
		"resource": resource_ref(resource.document),
		"path": sprintf("%s.initContainers[%d].env[%d]", [pod_spec_path(resource.document), index, env_index]),
		"message": sprintf("credential environment variable %s must use valueFrom.secretKeyRef", [object.get(env, "name", "")]),
	}
}

uses_latest_tag(image) if {
	parts := split(image, "@")
	ref := parts[0]
	endswith(ref, ":latest")
	not contains(image, "@sha256:")
}

has_valid_sha256_digest(image) if {
	regex.match("@sha256:[0-9a-f]{64}$", image)
}

common_policy_scope if {
	object.get(input, "context", null) == null
}

common_policy_scope if {
	context := object.get(input, "context", {})
	context != null
	not object.get(context, "skipCommonPoliciesForMixedRender", false)
}

credential_env_name(name) if regex.match("(^|_)(SECRET|TOKEN|PASSWORD|ACCESS_KEY|ACCESSKEY|PRIVATE_KEY)($|_)", name)
credential_env_name(name) if name == "RCLONE_AUTH_KEY"

credential_uses_secret_key_ref(env) if {
	value_from := object.get(env, "valueFrom", null)
	secret_key_ref := object.get(value_from, "secretKeyRef", null)
	secret_key_ref != null
}

pod_spec_containers(document) := containers if {
	spec := pod_spec(document)
	containers := object.get(spec, "containers", [])
}

pod_spec_init_containers(document) := init_containers if {
	spec := pod_spec(document)
	init_containers := object.get(spec, "initContainers", [])
}

pod_spec_ephemeral_containers(document) := ephemeral_containers if {
	spec := pod_spec(document)
	ephemeral_containers := object.get(spec, "ephemeralContainers", [])
}

pod_spec(document) := spec if {
	object.get(document, "kind", "") == "Pod"
	spec := object.get(document, "spec", {})
} else := spec if {
	kind := object.get(document, "kind", "")
	kind in {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}
	spec := object.get(object.get(object.get(document, "spec", {}), "template", {}), "spec", {})
} else := spec if {
	object.get(document, "kind", "") == "CronJob"
	spec := object.get(
		object.get(
			object.get(
				object.get(
					object.get(document, "spec", {}),
					"jobTemplate",
					{},
				),
				"spec",
				{},
			),
			"template",
			{},
		),
		"spec",
		{},
	)
}

pod_spec_path(document) := "spec" if {
	object.get(document, "kind", "") == "Pod"
} else := "spec.template.spec" if {
	kind := object.get(document, "kind", "")
	kind in {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}
} else := "spec.jobTemplate.spec.template.spec" if {
	object.get(document, "kind", "") == "CronJob"
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
