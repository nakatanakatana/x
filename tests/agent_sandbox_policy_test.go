package main

import (
	"testing"
)

func TestAgentSandboxPolicies(t *testing.T) {
	evaluator := newTestPolicyEvaluator(t)

	t.Run("rendered clusters/vcluster-agent passes all policies", func(t *testing.T) {
		resources, err := renderKustomization(t.Context(), "..", "clusters/vcluster-agent")
		if err != nil {
			t.Fatal(err)
		}
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: resources,
			Context:   policyContext("agent-sandbox"),
		})
	})

	negativeCases := []struct {
		name       string
		policyName string
		resources  []PolicyResource
		context    map[string]any
	}{
		{
			name:       "rejects SandboxTemplate without automountServiceAccountToken false",
			policyName: "sandbox-template-must-disable-service-account-token",
			resources: []PolicyResource{{
				Source: "tests/agent-sandbox/sandbox-template.yaml",
				Document: validSandboxTemplateDocument(func(podSpec map[string]any) {
					delete(podSpec, "automountServiceAccountToken")
				}),
			}},
		},
		{
			name:       "rejects SandboxTemplate without runAsNonRoot true",
			policyName: "sandbox-template-must-run-as-non-root",
			resources: []PolicyResource{{
				Source: "tests/agent-sandbox/sandbox-template.yaml",
				Document: validSandboxTemplateDocument(func(podSpec map[string]any) {
					secCtx := podSpec["securityContext"].(map[string]any)
					delete(secCtx, "runAsNonRoot")
				}),
			}},
		},
		{
			name:       "rejects SandboxTemplate without RuntimeDefault seccompProfile",
			policyName: "sandbox-template-must-run-as-non-root",
			resources: []PolicyResource{{
				Source: "tests/agent-sandbox/sandbox-template.yaml",
				Document: validSandboxTemplateDocument(func(podSpec map[string]any) {
					secCtx := podSpec["securityContext"].(map[string]any)
					delete(secCtx, "seccompProfile")
				}),
			}},
		},
		{
			name:       "rejects SandboxTemplate container without allowPrivilegeEscalation false",
			policyName: "sandbox-template-must-harden-containers",
			resources: []PolicyResource{{
				Source: "tests/agent-sandbox/sandbox-template.yaml",
				Document: validSandboxTemplateDocument(func(podSpec map[string]any) {
					container := podSpec["containers"].([]any)[0].(map[string]any)
					secCtx := container["securityContext"].(map[string]any)
					delete(secCtx, "allowPrivilegeEscalation")
				}),
			}},
		},
		{
			name:       "rejects SandboxTemplate container without dropping ALL capabilities",
			policyName: "sandbox-template-must-harden-containers",
			resources: []PolicyResource{{
				Source: "tests/agent-sandbox/sandbox-template.yaml",
				Document: validSandboxTemplateDocument(func(podSpec map[string]any) {
					container := podSpec["containers"].([]any)[0].(map[string]any)
					secCtx := container["securityContext"].(map[string]any)
					delete(secCtx, "capabilities")
				}),
			}},
		},
		{
			name:       "rejects SandboxTemplate with unpinned container image",
			policyName: "sandbox-template-image-must-be-digest-pinned",
			resources: []PolicyResource{{
				Source: "tests/agent-sandbox/sandbox-template.yaml",
				Document: validSandboxTemplateDocument(func(podSpec map[string]any) {
					container := podSpec["containers"].([]any)[0].(map[string]any)
					container["image"] = "ghcr.io/anomalyco/opencode:2.3.2"
				}),
			}},
		},
		{
			name:       "rejects SandboxTemplate with latest initContainer image",
			policyName: "sandbox-template-image-must-be-digest-pinned",
			resources: []PolicyResource{{
				Source: "tests/agent-sandbox/sandbox-template.yaml",
				Document: validSandboxTemplateDocument(func(podSpec map[string]any) {
					podSpec["initContainers"] = []any{
						map[string]any{
							"name":  "init",
							"image": "busybox:latest",
							"securityContext": map[string]any{
								"allowPrivilegeEscalation": false,
								"capabilities": map[string]any{
									"drop": []any{"ALL"},
								},
							},
						},
					}
				}),
			}},
		},
		{
			name:       "rejects SandboxTemplate with plaintext credential env var",
			policyName: "sandbox-template-credentials-must-use-secret-key-ref",
			resources: []PolicyResource{{
				Source: "tests/agent-sandbox/sandbox-template.yaml",
				Document: validSandboxTemplateDocument(func(podSpec map[string]any) {
					container := podSpec["containers"].([]any)[0].(map[string]any)
					container["env"] = []any{
						map[string]any{
							"name":  "OPENCODE_SERVER_PASSWORD",
							"value": "plaintext-password",
						},
					}
				}),
			}},
		},
		{
			name:       "rejects missing sandbox-default-deny NetworkPolicy under agent-sandbox scope",
			policyName: "sandbox-namespace-must-have-default-deny-networkpolicy",
			resources: []PolicyResource{
				{
					Source:   "tests/agent-sandbox/egress-proxy.yaml",
					Document: validEgressProxyDeploymentDocument(nil, nil),
				},
			},
			context: policyContext("agent-sandbox"),
		},
		{
			name:       "rejects sandbox-default-deny NetworkPolicy missing Egress policyType",
			policyName: "sandbox-namespace-must-have-default-deny-networkpolicy",
			resources: []PolicyResource{
				{
					Source:   "tests/agent-sandbox/egress-proxy.yaml",
					Document: validEgressProxyDeploymentDocument(nil, nil),
				},
				{
					Source: "tests/agent-sandbox/network-policy.yaml",
					Document: map[string]any{
						"apiVersion": "networking.k8s.io/v1",
						"kind":       "NetworkPolicy",
						"metadata": map[string]any{
							"name":      "sandbox-default-deny",
							"namespace": "sandbox",
						},
						"spec": map[string]any{
							"podSelector": map[string]any{},
							"policyTypes": []any{"Ingress"},
						},
					},
				},
			},
			context: policyContext("agent-sandbox"),
		},
		{
			name:       "rejects missing egress-proxy Deployment under agent-sandbox scope",
			policyName: "egress-proxy-must-be-hardened",
			resources: []PolicyResource{
				{
					Source:   "tests/agent-sandbox/network-policy.yaml",
					Document: validSandboxDefaultDenyNetworkPolicyDocument(),
				},
			},
			context: policyContext("agent-sandbox"),
		},
		{
			name:       "rejects egress-proxy Deployment without readOnlyRootFilesystem true",
			policyName: "egress-proxy-must-be-hardened",
			resources: []PolicyResource{
				{
					Source:   "tests/agent-sandbox/network-policy.yaml",
					Document: validSandboxDefaultDenyNetworkPolicyDocument(),
				},
				{
					Source: "tests/agent-sandbox/egress-proxy.yaml",
					Document: validEgressProxyDeploymentDocument(nil, func(container map[string]any) {
						secCtx := container["securityContext"].(map[string]any)
						secCtx["readOnlyRootFilesystem"] = false
					}),
				},
			},
			context: policyContext("agent-sandbox"),
		},
		{
			name:       "rejects egress-proxy Deployment without automountServiceAccountToken false",
			policyName: "egress-proxy-must-be-hardened",
			resources: []PolicyResource{
				{
					Source:   "tests/agent-sandbox/network-policy.yaml",
					Document: validSandboxDefaultDenyNetworkPolicyDocument(),
				},
				{
					Source: "tests/agent-sandbox/egress-proxy.yaml",
					Document: validEgressProxyDeploymentDocument(func(podSpec map[string]any) {
						delete(podSpec, "automountServiceAccountToken")
					}, nil),
				},
			},
			context: policyContext("agent-sandbox"),
		},
		{
			name:       "rejects egress-proxy Deployment without runAsNonRoot true",
			policyName: "egress-proxy-must-be-hardened",
			resources: []PolicyResource{
				{
					Source:   "tests/agent-sandbox/network-policy.yaml",
					Document: validSandboxDefaultDenyNetworkPolicyDocument(),
				},
				{
					Source: "tests/agent-sandbox/egress-proxy.yaml",
					Document: validEgressProxyDeploymentDocument(func(podSpec map[string]any) {
						secCtx := podSpec["securityContext"].(map[string]any)
						secCtx["runAsNonRoot"] = false
					}, nil),
				},
			},
			context: policyContext("agent-sandbox"),
		},
		{
			name:       "rejects egress-proxy Deployment without allowPrivilegeEscalation false",
			policyName: "egress-proxy-must-be-hardened",
			resources: []PolicyResource{
				{
					Source:   "tests/agent-sandbox/network-policy.yaml",
					Document: validSandboxDefaultDenyNetworkPolicyDocument(),
				},
				{
					Source: "tests/agent-sandbox/egress-proxy.yaml",
					Document: validEgressProxyDeploymentDocument(nil, func(container map[string]any) {
						secCtx := container["securityContext"].(map[string]any)
						delete(secCtx, "allowPrivilegeEscalation")
					}),
				},
			},
			context: policyContext("agent-sandbox"),
		},
		{
			name:       "rejects SandboxWarmPool referencing a missing SandboxTemplate",
			policyName: "sandbox-warmpool-must-reference-existing-template",
			resources: []PolicyResource{
				{
					Source:   "tests/agent-sandbox/network-policy.yaml",
					Document: validSandboxDefaultDenyNetworkPolicyDocument(),
				},
				{
					Source:   "tests/agent-sandbox/egress-proxy.yaml",
					Document: validEgressProxyDeploymentDocument(nil, nil),
				},
				{
					Source:   "tests/agent-sandbox/sandbox-template.yaml",
					Document: validSandboxTemplateDocument(nil),
				},
				{
					Source: "tests/agent-sandbox/warmpool.yaml",
					Document: map[string]any{
						"apiVersion": "extensions.agents.x-k8s.io/v1beta1",
						"kind":       "SandboxWarmPool",
						"metadata": map[string]any{
							"name":      "opencode-ephemeral-pool",
							"namespace": "sandbox",
						},
						"spec": map[string]any{
							"replicas": 1,
							"sandboxTemplateRef": map[string]any{
								"name": "missing-template",
							},
						},
					},
				},
			},
			context: policyContext("agent-sandbox"),
		},
		{
			name:       "rejects ClusterRoleBinding referencing ServiceAccount/sandbox-control",
			policyName: "sandbox-control-rbac-must-be-namespace-scoped",
			resources: []PolicyResource{
				{
					Source: "tests/agent-sandbox/cluster-role-binding.yaml",
					Document: map[string]any{
						"apiVersion": "rbac.authorization.k8s.io/v1",
						"kind":       "ClusterRoleBinding",
						"metadata": map[string]any{
							"name": "sandbox-control-cluster-admin",
						},
						"roleRef": map[string]any{
							"apiGroup": "rbac.authorization.k8s.io",
							"kind":     "ClusterRole",
							"name":     "cluster-admin",
						},
						"subjects": []any{
							map[string]any{
								"kind":      "ServiceAccount",
								"name":      "sandbox-control",
								"namespace": "agent-sandbox-system",
							},
						},
					},
				},
			},
		},
		{
			name:       "rejects RoleBinding for sandbox-control outside sandbox namespace",
			policyName: "sandbox-control-rbac-must-be-namespace-scoped",
			resources: []PolicyResource{
				{
					Source: "tests/agent-sandbox/role-binding.yaml",
					Document: map[string]any{
						"apiVersion": "rbac.authorization.k8s.io/v1",
						"kind":       "RoleBinding",
						"metadata": map[string]any{
							"name":      "sandbox-control-proxy",
							"namespace": "proxy",
						},
						"roleRef": map[string]any{
							"apiGroup": "rbac.authorization.k8s.io",
							"kind":     "Role",
							"name":     "sandbox-control",
						},
						"subjects": []any{
							map[string]any{
								"kind":      "ServiceAccount",
								"name":      "sandbox-control",
								"namespace": "agent-sandbox-system",
							},
						},
					},
				},
			},
		},
		{
			name:       "rejects Role for sandbox-control granting secrets access",
			policyName: "sandbox-control-rbac-must-be-namespace-scoped",
			resources: []PolicyResource{
				{
					Source: "tests/agent-sandbox/role.yaml",
					Document: map[string]any{
						"apiVersion": "rbac.authorization.k8s.io/v1",
						"kind":       "Role",
						"metadata": map[string]any{
							"name":      "sandbox-control",
							"namespace": "sandbox",
						},
						"rules": []any{
							map[string]any{
								"apiGroups": []any{""},
								"resources": []any{"secrets"},
								"verbs":     []any{"get"},
							},
						},
					},
				},
			},
		},
		{
			name:       "rejects Role for sandbox-control granting configmaps access",
			policyName: "sandbox-control-rbac-must-be-namespace-scoped",
			resources: []PolicyResource{
				{
					Source: "tests/agent-sandbox/role.yaml",
					Document: map[string]any{
						"apiVersion": "rbac.authorization.k8s.io/v1",
						"kind":       "Role",
						"metadata": map[string]any{
							"name":      "sandbox-control",
							"namespace": "sandbox",
						},
						"rules": []any{
							map[string]any{
								"apiGroups": []any{""},
								"resources": []any{"configmaps"},
								"verbs":     []any{"get"},
							},
						},
					},
				},
			},
		},
		{
			name:       "rejects Role bound to sandbox-control granting wildcard verbs",
			policyName: "sandbox-control-rbac-must-be-namespace-scoped",
			resources: []PolicyResource{
				{
					Source: "tests/agent-sandbox/role.yaml",
					Document: map[string]any{
						"apiVersion": "rbac.authorization.k8s.io/v1",
						"kind":       "Role",
						"metadata": map[string]any{
							"name":      "custom-sandbox-role",
							"namespace": "sandbox",
						},
						"rules": []any{
							map[string]any{
								"apiGroups": []any{"agents.x-k8s.io"},
								"resources": []any{"sandboxes"},
								"verbs":     []any{"*"},
							},
						},
					},
				},
				{
					Source: "tests/agent-sandbox/role-binding.yaml",
					Document: map[string]any{
						"apiVersion": "rbac.authorization.k8s.io/v1",
						"kind":       "RoleBinding",
						"metadata": map[string]any{
							"name":      "custom-sandbox-binding",
							"namespace": "sandbox",
						},
						"roleRef": map[string]any{
							"apiGroup": "rbac.authorization.k8s.io",
							"kind":     "Role",
							"name":     "custom-sandbox-role",
						},
						"subjects": []any{
							map[string]any{
								"kind":      "ServiceAccount",
								"name":      "sandbox-control",
								"namespace": "agent-sandbox-system",
							},
						},
					},
				},
			},
		},
		{
			name:       "rejects SandboxTemplate/opencode-persistent missing rook-ceph-block volumeClaimTemplates",
			policyName: "sandbox-persistent-template-must-use-ceph-block",
			resources: []PolicyResource{
				{
					Source:   "tests/agent-sandbox/sandbox-template-persistent.yaml",
					Document: validPersistentSandboxTemplateDocument(func(spec map[string]any) {
						delete(spec, "volumeClaimTemplates")
					}),
				},
			},
		},
		{
			name:       "rejects SandboxTemplate/opencode-persistent with non-rook-ceph-block storageClassName",
			policyName: "sandbox-persistent-template-must-use-ceph-block",
			resources: []PolicyResource{
				{
					Source: "tests/agent-sandbox/sandbox-template-persistent.yaml",
					Document: validPersistentSandboxTemplateDocument(func(spec map[string]any) {
						vcts := spec["volumeClaimTemplates"].([]any)
						vctSpec := vcts[0].(map[string]any)["spec"].(map[string]any)
						vctSpec["storageClassName"] = "local-path"
					}),
				},
			},
		},
		{
			name:       "rejects SandboxTemplate/opencode-persistent without ReadWriteOnce access mode",
			policyName: "sandbox-persistent-template-must-use-ceph-block",
			resources: []PolicyResource{
				{
					Source: "tests/agent-sandbox/sandbox-template-persistent.yaml",
					Document: validPersistentSandboxTemplateDocument(func(spec map[string]any) {
						vcts := spec["volumeClaimTemplates"].([]any)
						vctSpec := vcts[0].(map[string]any)["spec"].(map[string]any)
						vctSpec["accessModes"] = []any{"ReadWriteMany"}
					}),
				},
			},
		},
	}

	for _, tc := range negativeCases {
		t.Run(tc.name, func(t *testing.T) {
			assertPolicyFails(t, evaluator, PolicyInput{
				Resources: tc.resources,
				Context:   tc.context,
			}, tc.policyName)
		})
	}
}

func validSandboxTemplateDocument(mutatePodSpec func(map[string]any)) map[string]any {
	podSpec := map[string]any{
		"automountServiceAccountToken": false,
		"securityContext": map[string]any{
			"runAsNonRoot": true,
			"seccompProfile": map[string]any{
				"type": "RuntimeDefault",
			},
		},
		"containers": []any{
			map[string]any{
				"name":  "opencode",
				"image": "ghcr.io/anomalyco/opencode:2.3.2@sha256:be07cc4afd6d668d91b77accf1bc4338c87b39fbacc0a61666eb003781015f5a",
				"env": []any{
					map[string]any{
						"name": "OPENCODE_SERVER_PASSWORD",
						"valueFrom": map[string]any{
							"secretKeyRef": map[string]any{
								"name": "opencode-server-auth",
								"key":  "OPENCODE_SERVER_PASSWORD",
							},
						},
					},
				},
				"securityContext": map[string]any{
					"allowPrivilegeEscalation": false,
					"capabilities": map[string]any{
						"drop": []any{"ALL"},
					},
				},
			},
		},
	}
	if mutatePodSpec != nil {
		mutatePodSpec(podSpec)
	}
	return map[string]any{
		"apiVersion": "extensions.agents.x-k8s.io/v1beta1",
		"kind":       "SandboxTemplate",
		"metadata": map[string]any{
			"name":      "opencode-ephemeral",
			"namespace": "sandbox",
		},
		"spec": map[string]any{
			"podTemplate": map[string]any{
				"spec": podSpec,
			},
		},
	}
}

func validPersistentSandboxTemplateDocument(mutateSpec func(map[string]any)) map[string]any {
	doc := validSandboxTemplateDocument(nil)
	doc["metadata"].(map[string]any)["name"] = "opencode-persistent"
	spec := doc["spec"].(map[string]any)
	spec["volumeClaimTemplates"] = []any{
		map[string]any{
			"metadata": map[string]any{
				"name": "workspace",
			},
			"spec": map[string]any{
				"accessModes":      []any{"ReadWriteOnce"},
				"storageClassName": "rook-ceph-block",
				"resources": map[string]any{
					"requests": map[string]any{
						"storage": "20Gi",
					},
				},
			},
		},
	}
	if mutateSpec != nil {
		mutateSpec(spec)
	}
	return doc
}

func validSandboxDefaultDenyNetworkPolicyDocument() map[string]any {
	return map[string]any{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "NetworkPolicy",
		"metadata": map[string]any{
			"name":      "sandbox-default-deny",
			"namespace": "sandbox",
		},
		"spec": map[string]any{
			"podSelector": map[string]any{},
			"policyTypes": []any{"Ingress", "Egress"},
		},
	}
}

func validEgressProxyDeploymentDocument(mutatePodSpec func(map[string]any), mutateContainer func(map[string]any)) map[string]any {
	container := map[string]any{
		"name":  "egress-proxy",
		"image": "docker.io/mitmproxy/mitmproxy:12.3.1@sha256:2711066c855659b5af8b1dbb84494ed3eff69b42ece439c60b4fe09a2db829d4",
		"securityContext": map[string]any{
			"allowPrivilegeEscalation": false,
			"readOnlyRootFilesystem":   true,
			"capabilities": map[string]any{
				"drop": []any{"ALL"},
			},
		},
	}
	if mutateContainer != nil {
		mutateContainer(container)
	}
	podSpec := map[string]any{
		"automountServiceAccountToken": false,
		"securityContext": map[string]any{
			"runAsNonRoot": true,
			"seccompProfile": map[string]any{
				"type": "RuntimeDefault",
			},
		},
		"containers": []any{container},
	}
	if mutatePodSpec != nil {
		mutatePodSpec(podSpec)
	}
	return map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]any{
			"name":      "egress-proxy",
			"namespace": "proxy",
		},
		"spec": map[string]any{
			"template": map[string]any{
				"spec": podSpec,
			},
		},
	}
}
