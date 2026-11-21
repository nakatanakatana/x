package manifest_policy

import rego.v1

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	pod := sandbox_template_pod_spec(resource.document)
	object.get(pod, "automountServiceAccountToken", true) != false

	violation := {
		"policy": "sandbox-template-must-disable-service-account-token",
		"resource": resource_ref(resource.document),
		"path": "spec.podTemplate.spec.automountServiceAccountToken",
		"message": "SandboxTemplate must set spec.podTemplate.spec.automountServiceAccountToken to false",
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	pod_security := object.get(sandbox_template_pod_spec(resource.document), "securityContext", {})
	object.get(pod_security, "runAsNonRoot", false) != true

	violation := {
		"policy": "sandbox-template-must-run-as-non-root",
		"resource": resource_ref(resource.document),
		"path": "spec.podTemplate.spec.securityContext.runAsNonRoot",
		"message": "SandboxTemplate must set spec.podTemplate.spec.securityContext.runAsNonRoot to true",
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	pod_security := object.get(sandbox_template_pod_spec(resource.document), "securityContext", {})
	seccomp := object.get(pod_security, "seccompProfile", {})
	object.get(seccomp, "type", "") != "RuntimeDefault"

	violation := {
		"policy": "sandbox-template-must-run-as-non-root",
		"resource": resource_ref(resource.document),
		"path": "spec.podTemplate.spec.securityContext.seccompProfile.type",
		"message": "SandboxTemplate must set spec.podTemplate.spec.securityContext.seccompProfile.type to RuntimeDefault",
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	container := sandbox_template_containers(resource.document)[index]
	container_security := object.get(container, "securityContext", {})
	object.get(container_security, "allowPrivilegeEscalation", true) != false

	violation := {
		"policy": "sandbox-template-must-harden-containers",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.podTemplate.spec.containers[%d].securityContext.allowPrivilegeEscalation", [index]),
		"message": "SandboxTemplate container must set securityContext.allowPrivilegeEscalation to false",
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	container := sandbox_template_containers(resource.document)[index]
	container_security := object.get(container, "securityContext", {})
	not drop_all_capabilities(container_security)

	violation := {
		"policy": "sandbox-template-must-harden-containers",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.podTemplate.spec.containers[%d].securityContext.capabilities.drop", [index]),
		"message": "SandboxTemplate container must drop ALL Linux capabilities",
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	container := sandbox_template_init_containers(resource.document)[index]
	container_security := object.get(container, "securityContext", {})
	object.get(container_security, "allowPrivilegeEscalation", true) != false

	violation := {
		"policy": "sandbox-template-must-harden-containers",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.podTemplate.spec.initContainers[%d].securityContext.allowPrivilegeEscalation", [index]),
		"message": "SandboxTemplate initContainer must set securityContext.allowPrivilegeEscalation to false",
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	container := sandbox_template_init_containers(resource.document)[index]
	container_security := object.get(container, "securityContext", {})
	not drop_all_capabilities(container_security)

	violation := {
		"policy": "sandbox-template-must-harden-containers",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.podTemplate.spec.initContainers[%d].securityContext.capabilities.drop", [index]),
		"message": "SandboxTemplate initContainer must drop ALL Linux capabilities",
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	container := sandbox_template_containers(resource.document)[index]
	image := object.get(container, "image", "")
	not sandbox_template_image_pinned(image)

	violation := {
		"policy": "sandbox-template-image-must-be-digest-pinned",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.podTemplate.spec.containers[%d].image", [index]),
		"message": "SandboxTemplate container image must include a valid sha256 digest and must not use the latest tag",
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	container := sandbox_template_init_containers(resource.document)[index]
	image := object.get(container, "image", "")
	not sandbox_template_image_pinned(image)

	violation := {
		"policy": "sandbox-template-image-must-be-digest-pinned",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.podTemplate.spec.initContainers[%d].image", [index]),
		"message": "SandboxTemplate initContainer image must include a valid sha256 digest and must not use the latest tag",
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	container := sandbox_template_containers(resource.document)[index]
	env := object.get(container, "env", [])[env_index]
	env_name := upper(object.get(env, "name", ""))
	credential_env_name(env_name)
	not credential_uses_secret_key_ref(env)

	violation := {
		"policy": "sandbox-template-credentials-must-use-secret-key-ref",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.podTemplate.spec.containers[%d].env[%d]", [index, env_index]),
		"message": sprintf("credential environment variable %s must use valueFrom.secretKeyRef", [object.get(env, "name", "")]),
	}
}

violations contains violation if {
	resource := input.resources[_]
	sandbox_template(resource.document)
	container := sandbox_template_init_containers(resource.document)[index]
	env := object.get(container, "env", [])[env_index]
	env_name := upper(object.get(env, "name", ""))
	credential_env_name(env_name)
	not credential_uses_secret_key_ref(env)

	violation := {
		"policy": "sandbox-template-credentials-must-use-secret-key-ref",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.podTemplate.spec.initContainers[%d].env[%d]", [index, env_index]),
		"message": sprintf("credential environment variable %s must use valueFrom.secretKeyRef", [object.get(env, "name", "")]),
	}
}

violations contains violation if {
	agent_sandbox_scope
	not sandbox_default_deny_networkpolicy_exists

	violation := {
		"policy": "sandbox-namespace-must-have-default-deny-networkpolicy",
		"resource": "networking.k8s.io/NetworkPolicy/sandbox/sandbox-default-deny",
		"path": "spec.policyTypes",
		"message": "agent-sandbox manifests must include NetworkPolicy/sandbox-default-deny in namespace sandbox with both Ingress and Egress policyTypes",
	}
}

violations contains violation if {
	agent_sandbox_scope
	not egress_proxy_deployment_exists

	violation := {
		"policy": "egress-proxy-must-be-hardened",
		"resource": "apps/Deployment/proxy/egress-proxy",
		"path": "spec.template.spec",
		"message": "agent-sandbox manifests must include hardened Deployment/egress-proxy in namespace proxy",
	}
}

violations contains violation if {
	agent_sandbox_scope
	resource := input.resources[_]
	egress_proxy_deployment(resource.document)
	pod := pod_spec(resource.document)
	object.get(pod, "automountServiceAccountToken", true) != false

	violation := {
		"policy": "egress-proxy-must-be-hardened",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.automountServiceAccountToken",
		"message": "Deployment/egress-proxy must set automountServiceAccountToken to false",
	}
}

violations contains violation if {
	agent_sandbox_scope
	resource := input.resources[_]
	egress_proxy_deployment(resource.document)
	pod_security := object.get(pod_spec(resource.document), "securityContext", {})
	object.get(pod_security, "runAsNonRoot", false) != true

	violation := {
		"policy": "egress-proxy-must-be-hardened",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.securityContext.runAsNonRoot",
		"message": "Deployment/egress-proxy must set securityContext.runAsNonRoot to true",
	}
}

violations contains violation if {
	agent_sandbox_scope
	resource := input.resources[_]
	egress_proxy_deployment(resource.document)
	count(pod_spec_containers(resource.document)) == 0

	violation := {
		"policy": "egress-proxy-must-be-hardened",
		"resource": resource_ref(resource.document),
		"path": "spec.template.spec.containers",
		"message": "Deployment/egress-proxy must define at least one hardened container",
	}
}

violations contains violation if {
	agent_sandbox_scope
	resource := input.resources[_]
	egress_proxy_deployment(resource.document)
	container := pod_spec_containers(resource.document)[index]
	container_security := object.get(container, "securityContext", {})
	object.get(container_security, "readOnlyRootFilesystem", false) != true

	violation := {
		"policy": "egress-proxy-must-be-hardened",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.template.spec.containers[%d].securityContext.readOnlyRootFilesystem", [index]),
		"message": "Deployment/egress-proxy container must set securityContext.readOnlyRootFilesystem to true",
	}
}

violations contains violation if {
	agent_sandbox_scope
	resource := input.resources[_]
	egress_proxy_deployment(resource.document)
	container := pod_spec_containers(resource.document)[index]
	container_security := object.get(container, "securityContext", {})
	object.get(container_security, "allowPrivilegeEscalation", true) != false

	violation := {
		"policy": "egress-proxy-must-be-hardened",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.template.spec.containers[%d].securityContext.allowPrivilegeEscalation", [index]),
		"message": "Deployment/egress-proxy container must set securityContext.allowPrivilegeEscalation to false",
	}
}

violations contains violation if {
	agent_sandbox_scope
	resource := input.resources[_]
	egress_proxy_deployment(resource.document)
	container := pod_spec_init_containers(resource.document)[index]
	container_security := object.get(container, "securityContext", {})
	object.get(container_security, "readOnlyRootFilesystem", false) != true

	violation := {
		"policy": "egress-proxy-must-be-hardened",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.template.spec.initContainers[%d].securityContext.readOnlyRootFilesystem", [index]),
		"message": "Deployment/egress-proxy initContainer must set securityContext.readOnlyRootFilesystem to true",
	}
}

violations contains violation if {
	agent_sandbox_scope
	resource := input.resources[_]
	egress_proxy_deployment(resource.document)
	container := pod_spec_init_containers(resource.document)[index]
	container_security := object.get(container, "securityContext", {})
	object.get(container_security, "allowPrivilegeEscalation", true) != false

	violation := {
		"policy": "egress-proxy-must-be-hardened",
		"resource": resource_ref(resource.document),
		"path": sprintf("spec.template.spec.initContainers[%d].securityContext.allowPrivilegeEscalation", [index]),
		"message": "Deployment/egress-proxy initContainer must set securityContext.allowPrivilegeEscalation to false",
	}
}

agent_sandbox_scope if {
	object.get(object.get(input, "context", {}), "policyScope", "") == "agent-sandbox"
}

agent_sandbox_scope if {
	object.get(object.get(input, "context", {}), "scope", "") == "agent-sandbox"
}

sandbox_template(document) if {
	object.get(document, "kind", "") == "SandboxTemplate"
}

sandbox_template_pod_spec(document) := object.get(
	object.get(object.get(document, "spec", {}), "podTemplate", {}),
	"spec",
	{},
)

sandbox_template_containers(document) := object.get(sandbox_template_pod_spec(document), "containers", [])

sandbox_template_init_containers(document) := object.get(sandbox_template_pod_spec(document), "initContainers", [])

sandbox_template_image_pinned(image) if {
	image != ""
	not uses_latest_tag(image)
	has_valid_sha256_digest(image)
}

sandbox_default_deny_networkpolicy_exists if {
	resource := input.resources[_]
	document := resource.document
	object.get(document, "kind", "") == "NetworkPolicy"
	resource_namespace(document) == "sandbox"
	resource_name(document) == "sandbox-default-deny"
	policy_types := object.get(object.get(document, "spec", {}), "policyTypes", [])
	policy_types[_] == "Ingress"
	policy_types[_] == "Egress"
}

egress_proxy_deployment(document) if {
	object.get(document, "kind", "") == "Deployment"
	resource_namespace(document) == "proxy"
	resource_name(document) == "egress-proxy"
}

egress_proxy_deployment_exists if {
	resource := input.resources[_]
	egress_proxy_deployment(resource.document)
}
