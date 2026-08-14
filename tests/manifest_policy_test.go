package main

import (
	"context"
	"path/filepath"
	"testing"
)

func TestPolicyFixtures(t *testing.T) {
	evaluator := newTestPolicyEvaluator(t)

	testCases := []struct {
		name              string
		fixture           string
		policyName        string
		context           map[string]any
		expectedResources []string
	}{
		{
			name:       "rejects mutable latest image tags",
			fixture:    "invalid-latest.yaml",
			policyName: "image-must-not-use-latest",
		},
		{
			name:       "rejects plaintext credential values",
			fixture:    "invalid-plaintext-credential.yaml",
			policyName: "credential-must-use-secret-key-ref",
		},
		{
			name:       "rejects scoped nodeport services",
			fixture:    "invalid-service-type.yaml",
			policyName: "service-must-not-use-nodeport",
			context:    policyContext("pcloud-s3"),
		},
		{
			name:       "rejects external secret refresh intervals below the minimum",
			fixture:    "invalid-refresh-interval.yaml",
			policyName: "external-secret-refresh-interval-must-be-at-least-12h",
			context:    policyContext("external-secrets"),
			expectedResources: []string{
				"external-secrets.io/ExternalSecret/default/too-fast-secret",
			},
		},
		{
			name:       "rejects malformed external secret refresh intervals",
			fixture:    "invalid-refresh-interval.yaml",
			policyName: "external-secret-refresh-interval-must-be-valid",
			context:    policyContext("external-secrets"),
			expectedResources: []string{
				"external-secrets.io/ExternalSecret/default/malformed-secret",
			},
		},
		{
			name:       "rejects duplicate external secret refresh intervals",
			fixture:    "invalid-refresh-interval.yaml",
			policyName: "external-secret-refresh-interval-must-be-unique",
			context:    policyContext("external-secrets"),
			expectedResources: []string{
				"external-secrets.io/ExternalSecret/default/duplicate-one",
				"external-secrets.io/ExternalSecret/default/duplicate-two",
			},
		},
		{
			name:       "rejects incorrect external secret cache settings",
			fixture:    "invalid-refresh-interval.yaml",
			policyName: "cluster-secret-store-must-configure-cache",
			context:    policyContext("external-secrets"),
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			resources, err := loadPolicyResources(filepath.Join("testdata", "policies", tc.fixture))
			if err != nil {
				t.Fatal(err)
			}
			input := PolicyInput{
				Resources: resources,
				Context:   tc.context,
			}
			if len(tc.expectedResources) == 0 {
				assertPolicyFails(t, evaluator, input, tc.policyName)
				return
			}
			assertPolicyFailsForResources(t, evaluator, input, tc.policyName, tc.expectedResources...)
		})
	}
}

func TestCommonPolicies(t *testing.T) {
	evaluator := newTestPolicyEvaluator(t)

	testCases := []struct {
		name       string
		policyName string
		failInput  PolicyInput
		passInput  PolicyInput
	}{
		{
			name:       "digest pinning is required for container images",
			policyName: "image-must-be-digest-pinned",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/images.yaml",
				Document: deploymentDocument("digest-check", "default", map[string]string{
					"image": "nginx:1.27.0",
				}, nil),
			}}},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/images.yaml",
				Document: deploymentDocument("digest-check", "default", map[string]string{
					"image": "nginx:1.27.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
				}, nil),
			}}},
		},
		{
			name:       "digest pinning rejects malformed sha256 digests",
			policyName: "image-must-be-digest-pinned",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/images.yaml",
				Document: deploymentDocument("malformed-digest-check", "default", map[string]string{
					"image": "nginx:1.27.0@sha256:not-a-digest",
				}, nil),
			}}},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/images.yaml",
				Document: deploymentDocument("valid-digest-check", "default", map[string]string{
					"image": "nginx:1.27.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
				}, nil),
			}}},
		},
		{
			name:       "init container images must be digest pinned",
			policyName: "image-must-be-digest-pinned",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source:   "tests/passing/images.yaml",
				Document: deploymentWithInitContainer("init-digest-check", "default", map[string]any{"image": "busybox:1.36.1"}),
			}}},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source:   "tests/passing/images.yaml",
				Document: deploymentWithInitContainer("init-digest-check", "default", map[string]any{"image": "busybox:1.36.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}),
			}}},
		},
		{
			name:       "credential values may come from secret references",
			policyName: "credential-must-use-secret-key-ref",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/credentials.yaml",
				Document: deploymentDocument("credential-check", "default", map[string]string{
					"AWS_SECRET_ACCESS_KEY": "plaintext-secret",
				}, nil),
			}}},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/credentials.yaml",
				Document: deploymentDocument("credential-check", "default", nil, []map[string]any{{
					"name": "AWS_SECRET_ACCESS_KEY",
					"valueFrom": map[string]any{
						"secretKeyRef": map[string]any{
							"name": "aws-credentials",
							"key":  "secret-access-key",
						},
					},
				}}),
			}}},
		},
		{
			name:       "credential values may not come from non-secret references",
			policyName: "credential-must-use-secret-key-ref",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/credentials.yaml",
				Document: deploymentDocument("credential-check", "default", nil, []map[string]any{{
					"name": "AWS_SECRET_ACCESS_KEY",
					"valueFrom": map[string]any{
						"configMapKeyRef": map[string]any{
							"name": "aws-credentials",
							"key":  "secret-access-key",
						},
					},
				}}),
			}}},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/credentials.yaml",
				Document: deploymentDocument("credential-check", "default", nil, []map[string]any{{
					"name": "AWS_SECRET_ACCESS_KEY",
					"valueFrom": map[string]any{
						"secretKeyRef": map[string]any{
							"name": "aws-credentials",
							"key":  "secret-access-key",
						},
					},
				}}),
			}}},
		},
		{
			name:       "pcloud auth key values must use secret references",
			policyName: "credential-must-use-secret-key-ref",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/credentials.yaml",
				Document: deploymentDocument("pcloud-credential-check", "pcloud-s3", map[string]string{
					"RCLONE_AUTH_KEY": "plaintext-secret",
				}, nil),
			}}, Context: policyContext("pcloud-s3")},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/credentials.yaml",
				Document: deploymentDocument("pcloud-credential-check", "pcloud-s3", nil, []map[string]any{{
					"name": "RCLONE_AUTH_KEY",
					"valueFrom": map[string]any{
						"secretKeyRef": map[string]any{
							"name": "rclone-s3-credentials",
							"key":  "RCLONE_AUTH_KEY",
						},
					},
				}}),
			}}, Context: policyContext("pcloud-s3")},
		},
		{
			name:       "init container images may not use the latest tag",
			policyName: "image-must-not-use-latest",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source:   "tests/passing/images.yaml",
				Document: deploymentWithInitContainer("init-image-check", "default", map[string]any{"image": "busybox:latest"}),
			}}},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source:   "tests/passing/images.yaml",
				Document: deploymentWithInitContainer("init-image-check", "default", map[string]any{"image": "busybox:1.36.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}),
			}}},
		},
		{
			name:       "init container credential values must use secret references",
			policyName: "credential-must-use-secret-key-ref",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/credentials.yaml",
				Document: deploymentWithInitContainer("init-credential-check", "default", map[string]any{
					"env": []any{
						map[string]any{
							"name":  "AWS_SECRET_ACCESS_KEY",
							"value": "plaintext-secret",
						},
					},
				}),
			}}},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/credentials.yaml",
				Document: deploymentWithInitContainer("init-credential-check", "default", map[string]any{
					"env": []any{
						map[string]any{
							"name": "AWS_SECRET_ACCESS_KEY",
							"valueFrom": map[string]any{
								"secretKeyRef": map[string]any{
									"name": "aws-credentials",
									"key":  "secret-access-key",
								},
							},
						},
					},
				}),
			}}},
		},
		{
			name:       "scoped services may not use load balancers",
			policyName: "service-must-not-use-loadbalancer",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source:   "tests/passing/services.yaml",
				Document: serviceDocument("gateway", "pcloud-s3", "LoadBalancer"),
			}}, Context: policyContext("pcloud-s3")},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source:   "tests/passing/services.yaml",
				Document: serviceDocument("gateway", "pcloud-s3", "ClusterIP"),
			}}, Context: policyContext("pcloud-s3")},
		},
		{
			name:       "pcloud gateway disables automounting the service account token",
			policyName: "workload-must-disable-service-account-token",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/workloads.yaml",
				Document: pcloudGatewayDeploymentDocument(map[string]any{
					"automountServiceAccountToken": true,
				}, nil),
			}}, Context: policyContext("pcloud-s3")},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source:   "tests/passing/workloads.yaml",
				Document: pcloudGatewayDeploymentDocument(nil, nil),
			}}, Context: policyContext("pcloud-s3")},
		},
		{
			name:       "pcloud gateway requires the pod security context from the current script contract",
			policyName: "workload-must-have-pod-security-context",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/workloads.yaml",
				Document: pcloudGatewayDeploymentDocument(map[string]any{
					"securityContext": map[string]any{
						"runAsNonRoot": false,
					},
				}, nil),
			}}, Context: policyContext("pcloud-s3")},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source:   "tests/passing/workloads.yaml",
				Document: pcloudGatewayDeploymentDocument(nil, nil),
			}}, Context: policyContext("pcloud-s3")},
		},
		{
			name:       "pcloud gateway requires the restricted container security context from the current script contract",
			policyName: "workload-must-have-container-security-context",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/workloads.yaml",
				Document: pcloudGatewayDeploymentDocument(nil, map[string]any{
					"securityContext": map[string]any{
						"allowPrivilegeEscalation": true,
					},
				}),
			}}, Context: policyContext("pcloud-s3")},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source:   "tests/passing/workloads.yaml",
				Document: pcloudGatewayDeploymentDocument(nil, nil),
			}}, Context: policyContext("pcloud-s3")},
		},
		{
			name:       "pcloud cache pvc keeps the expected storage class",
			policyName: "persistent-volume-claim-must-match-storage-class",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/storage.yaml",
				Document: pvcDocument(
					"rclone-s3-cache",
					"pcloud-s3",
					"standard",
					"50Gi",
				),
			}}, Context: policyContext("pcloud-s3")},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/storage.yaml",
				Document: pvcDocument(
					"rclone-s3-cache",
					"pcloud-s3",
					"rook-ceph-block",
					"50Gi",
				),
			}}, Context: policyContext("pcloud-s3")},
		},
		{
			name:       "pcloud cache pvc keeps the expected storage size",
			policyName: "persistent-volume-claim-must-match-storage-size",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/storage.yaml",
				Document: pvcDocument(
					"rclone-s3-cache",
					"pcloud-s3",
					"rook-ceph-block",
					"10Gi",
				),
			}}, Context: policyContext("pcloud-s3")},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/storage.yaml",
				Document: pvcDocument(
					"rclone-s3-cache",
					"pcloud-s3",
					"rook-ceph-block",
					"50Gi",
				),
			}}, Context: policyContext("pcloud-s3")},
		},
		{
			name:       "pcloud cache pvc keeps read write once access mode",
			policyName: "persistent-volume-claim-must-use-read-write-once",
			failInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/storage.yaml",
				Document: map[string]any{
					"apiVersion": "v1",
					"kind":       "PersistentVolumeClaim",
					"metadata": map[string]any{
						"name":      "rclone-s3-cache",
						"namespace": "pcloud-s3",
					},
					"spec": map[string]any{
						"accessModes":      []any{"ReadWriteMany"},
						"storageClassName": "rook-ceph-block",
						"resources": map[string]any{
							"requests": map[string]any{
								"storage": "50Gi",
							},
						},
					},
				},
			}}, Context: policyContext("pcloud-s3")},
			passInput: PolicyInput{Resources: []PolicyResource{{
				Source: "tests/passing/storage.yaml",
				Document: pvcDocument(
					"rclone-s3-cache",
					"pcloud-s3",
					"rook-ceph-block",
					"50Gi",
				),
			}}, Context: policyContext("pcloud-s3")},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			assertPolicyFails(t, evaluator, tc.failInput, tc.policyName)
			assertPolicyPasses(t, evaluator, tc.passInput)
		})
	}

	t.Run("digest-pinned latest tag is accepted", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{Resources: []PolicyResource{{
			Source: "tests/passing/images.yaml",
			Document: deploymentDocument("digest-latest-check", "default", map[string]string{
				"image": "nginx:latest@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			}, nil),
		}}})
	})

	t.Run("common policies remain active in scoped application contexts", func(t *testing.T) {
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source: "render:components/pcloud-s3",
				Document: deploymentDocument("scoped-image", "pcloud-s3", map[string]string{
					"image": "nginx:1.27.0",
				}, nil),
			}},
			Context: policyContext("pcloud-s3"),
		}, "image-must-be-digest-pinned")

		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source: "render:components/pcloud-s3",
				Document: deploymentDocument("scoped-credential", "pcloud-s3", nil, []map[string]any{{
					"name":  "PCLOUD_TOKEN",
					"value": "plaintext-token",
				}}),
			}},
			Context: policyContext("pcloud-s3"),
		}, "credential-must-use-secret-key-ref")
	})

	t.Run("credential detection does not match partial words", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source: "tests/passing/credentials.yaml",
				Document: deploymentDocument("non-credential-name", "default", nil, []map[string]any{{
					"name":  "TOKENIZER",
					"value": "application-setting",
				}}),
			}},
		})
	})

	t.Run("credential detection covers ephemeral containers", func(t *testing.T) {
		document := deploymentDocument("ephemeral-credential", "default", nil, nil)
		podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
		podSpec["ephemeralContainers"] = []any{map[string]any{
			"name":  "debug",
			"image": "busybox:1.36.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			"env": []any{map[string]any{
				"name":  "AWS_SECRET_ACCESS_KEY",
				"value": "plaintext-secret",
			}},
		}}
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source:   "tests/passing/credentials.yaml",
				Document: document,
			}},
		}, "credential-must-use-secret-key-ref")
	})

	t.Run("ephemeral container images must be digest pinned", func(t *testing.T) {
		document := deploymentDocument("ephemeral-digest", "default", nil, nil)
		podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
		podSpec["ephemeralContainers"] = []any{map[string]any{
			"name":  "debug",
			"image": "busybox:1.36.1",
		}}
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source:   "tests/passing/images.yaml",
				Document: document,
			}},
		}, "image-must-be-digest-pinned")

		podSpec["ephemeralContainers"].([]any)[0].(map[string]any)["image"] = "busybox:1.36.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source:   "tests/passing/images.yaml",
				Document: document,
			}},
		})
	})

	t.Run("ephemeral container images may not use the latest tag", func(t *testing.T) {
		document := deploymentDocument("ephemeral-latest", "default", nil, nil)
		podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
		podSpec["ephemeralContainers"] = []any{map[string]any{
			"name":  "debug",
			"image": "busybox:latest",
		}}
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source:   "tests/passing/images.yaml",
				Document: document,
			}},
		}, "image-must-not-use-latest")

		podSpec["ephemeralContainers"].([]any)[0].(map[string]any)["image"] = "busybox:1.36.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source:   "tests/passing/images.yaml",
				Document: document,
			}},
		})
	})

	t.Run("mixed renders may explicitly disable common policies", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{
				{
					Source: "tests/mixed-render",
					Document: deploymentDocument("mixed-image", "default", map[string]string{
						"image": "nginx:latest",
					}, nil),
				},
				{
					Source: "tests/mixed-render",
					Document: deploymentDocument("mixed-credential", "default", nil, []map[string]any{{
						"name":  "ACCESS_TOKEN",
						"value": "plaintext-token",
					}}),
				},
			},
			Context: policyContextWithCommonPoliciesDisabled("litestream"),
		})
	})
}

func TestLitestreamSemanticPolicies(t *testing.T) {
	evaluator := newTestPolicyEvaluator(t)

	controllerResources := mustRenderPolicyResources(t, "components/litestream-controller")
	hostConfigResources := mustLoadPolicyResources(t, repoPath("clusters", "home", "resources", "litestream-debug.yaml"))
	debugWorkloadResources := mustRenderPolicyResources(t, "clusters/vcluster-app/feed-reader-debug/workload")
	vclusterResources := mustRenderPolicyResources(t, "clusters/vcluster-app")
	namespaceResources := mustLoadCanonicalPolicyResources(t, "clusters/home/_system/namespaces/app.yaml")
	if len(matchingResources(vclusterResources, "Deployment", "feed-reader", "feed-reader-db-debug")) != 1 {
		t.Fatal("expected exactly one feed-reader-db-debug Deployment in the full vcluster render")
	}

	baseInput := PolicyInput{
		Resources: appendPolicyResources(
			controllerResources,
			hostConfigResources,
			debugWorkloadResources,
			vclusterResources,
			namespaceResources,
		),
		Context: policyContextWithFullContract("litestream"),
	}

	assertPolicyPasses(t, evaluator, baseInput)

	t.Run("rejects an empty full Litestream contract", func(t *testing.T) {
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: []PolicyResource{},
			Context:   policyContextWithCommonPoliciesDisabledAndFullContract("litestream"),
		}, "litestream-host-must-include-resources")
	})

	t.Run("rejects a full Litestream contract with all target sources missing", func(t *testing.T) {
		mutated := replaceAllResourceSources(baseInput.Resources, "render:unrelated")
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContextWithCommonPoliciesDisabledAndFullContract("litestream"),
		}, "litestream-host-must-include-resources")
	})

	t.Run("rejects missing litestream controller crds", func(t *testing.T) {
		filtered := removeResourceByName(baseInput.Resources, "CustomResourceDefinition", "", "litestreamreplicas.litestream.mytools.nakatanakatana.app")
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: filtered,
			Context:   policyContext("litestream"),
		}, "litestream-controller-must-install-crds")
	})

	t.Run("rejects broken debug workload injection contract", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Deployment", "feed-reader", "feed-reader-db-debug", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			template := document["spec"].(map[string]any)["template"].(map[string]any)
			annotations := cloneMap(template["metadata"].(map[string]any)["annotations"].(map[string]any))
			delete(annotations, "litestream.mytools.nakatanakatana.app/target-container")
			template["metadata"].(map[string]any)["annotations"] = annotations
			resource.Document = document
			return resource
		})

		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("litestream"),
		}, "litestream-debug-workload-must-match-injection-contract")
	})

	t.Run("rejects a debug workload without the sqlite3 container contract", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Deployment", "feed-reader", "feed-reader-db-debug", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
			podSpec["containers"] = []any{}
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: policyContext("litestream")}, "litestream-debug-workload-must-have-sqlite-container")
	})

	t.Run("does not require a particular keepalive command", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Deployment", "feed-reader", "feed-reader-db-debug", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
			containers := cloneSlice(podSpec["containers"].([]any))
			container := cloneMap(containers[0].(map[string]any))
			container["args"] = []any{"tail", "-f", "/dev/null"}
			containers[0] = container
			podSpec["containers"] = containers
			resource.Document = document
			return resource
		})
		assertPolicyPasses(t, evaluator, PolicyInput{Resources: mutated, Context: policyContext("litestream")})
	})

	t.Run("rejects a debug workload without the data emptyDir contract", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Deployment", "feed-reader", "feed-reader-db-debug", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
			podSpec["volumes"] = []any{}
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: policyContext("litestream")}, "litestream-debug-workload-must-use-data-emptydir")
	})

	t.Run("rejects a restore reference without a matching replica", func(t *testing.T) {
		mutated := removeResourceByName(baseInput.Resources, "LitestreamReplica", "app", "feed-reader-db-debug-source")
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("litestream"),
		}, "litestream-restore-must-reference-replica")
	})

	t.Run("rejects an unrelated same-identity replica", func(t *testing.T) {
		mutated := removeResourceByName(baseInput.Resources, "LitestreamReplica", "app", "feed-reader-db-debug-source")
		mutated = append(mutated, PolicyResource{
			Source: "render:clusters/other-app/resources/litestream.yaml",
			Document: map[string]any{
				"apiVersion": "litestream.mytools.nakatanakatana.app/v1alpha1",
				"kind":       "LitestreamReplica",
				"metadata": map[string]any{
					"name":      "feed-reader-db-debug-source",
					"namespace": "app",
				},
			},
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("litestream"),
		}, "litestream-restore-must-reference-replica")
	})

	for _, tc := range []struct {
		name         string
		kind         string
		ns           string
		nameToRemove string
		resource     string
	}{
		{name: "host Litestream", kind: "Litestream", ns: "app", nameToRemove: "feed-reader-db-debug", resource: "litestream-host-must-include-resources"},
		{name: "host LitestreamReplica", kind: "LitestreamReplica", ns: "app", nameToRemove: "feed-reader-db-debug-source", resource: "litestream-host-must-include-resources"},
		{name: "controller Deployment", kind: "Deployment", ns: "litestream-controller-system", nameToRemove: "litestream-controller-manager", resource: "litestream-controller-must-include-resources"},
		{name: "debug workload", kind: "Deployment", ns: "feed-reader", nameToRemove: "feed-reader-db-debug", resource: "litestream-debug-workload-must-include-resources"},
	} {
		t.Run("requires "+tc.name, func(t *testing.T) {
			mutated := removeResourceByKindName(baseInput.Resources, tc.kind, tc.ns, tc.nameToRemove)
			assertPolicyFails(t, evaluator, PolicyInput{
				Resources: mutated,
				Context:   policyContextWithCommonPoliciesDisabled("litestream"),
			}, tc.resource)
		})
	}

	t.Run("rejects a LitestreamReplica with replication enabled", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "LitestreamReplica", "app", "feed-reader-db-debug-source", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			replica := cloneMap(document["spec"].(map[string]any)["replica"].(map[string]any))
			replica["replicate"] = map[string]any{"databases": []any{"other"}}
			document["spec"].(map[string]any)["replica"] = replica
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: policyContext("litestream")}, "litestream-replica-must-not-enable-replication")
	})

	t.Run("requires the app namespace injection label", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Namespace", "", "app", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			delete(document["metadata"].(map[string]any)["labels"].(map[string]any), "litestream.mytools.nakatanakatana.app/injection")
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: policyContext("litestream")}, "litestream-app-namespace-must-enable-injection")
	})

	t.Run("controller source boundaries are enforced", func(t *testing.T) {
		nearMatchController := replaceAllResourceSources(controllerResources, "render:components/litestream-controller-other")
		mutated := appendPolicyResources(
			nearMatchController,
			hostConfigResources,
			debugWorkloadResources,
			vclusterResources,
		)
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContextWithCommonPoliciesDisabled("litestream"),
		}, "litestream-controller-must-include-resources")
	})

	t.Run("host source boundaries are enforced", func(t *testing.T) {
		nearMatchHost := replaceAllResourceSources(hostConfigResources, "render:clusters/home/resources/litestream-debug.yaml.bak")
		mutated := appendPolicyResources(
			controllerResources,
			nearMatchHost,
			debugWorkloadResources,
			vclusterResources,
		)
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContextWithCommonPoliciesDisabled("litestream"),
		}, "litestream-host-must-include-resources")
	})

	t.Run("debug workload source boundaries are enforced", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source:   "render:clusters/vcluster-app/feed-reader-debug/workload-old",
				Document: deploymentDocument("feed-reader-db-debug", "feed-reader", nil, nil),
			}},
			Context: policyContext("litestream"),
		})
	})

	t.Run("vcluster source boundaries are enforced", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source: "render:clusters/vcluster-app-other",
				Document: map[string]any{
					"apiVersion": "litestream.mytools.nakatanakatana.app/v1alpha1",
					"kind":       "Litestream",
					"metadata": map[string]any{
						"name":      "unrelated",
						"namespace": "feed-reader",
					},
				},
			}},
			Context: policyContext("litestream"),
		})
	})

	for _, tc := range []struct {
		name   string
		mutate func(PolicyResource) PolicyResource
	}{
		{
			name: "namespace",
			mutate: func(resource PolicyResource) PolicyResource {
				document := cloneMap(resource.Document)
				document["metadata"].(map[string]any)["namespace"] = "other"
				resource.Document = document
				return resource
			},
		},
		{
			name: "endpoint",
			mutate: func(resource PolicyResource) PolicyResource {
				document := cloneMap(resource.Document)
				s3 := litestreamReplicaS3(document)
				s3["endpoint"] = "http://storage-clusterip.tailscale.svc.cluster.local:8010"
				resource.Document = document
				return resource
			},
		},
		{
			name: "bucket",
			mutate: func(resource PolicyResource) PolicyResource {
				document := cloneMap(resource.Document)
				s3 := litestreamReplicaS3(document)
				s3["bucket"] = "other"
				resource.Document = document
				return resource
			},
		},
		{
			name: "database path",
			mutate: func(resource PolicyResource) PolicyResource {
				document := cloneMap(resource.Document)
				s3 := litestreamReplicaS3(document)
				s3["path"] = "other.db"
				resource.Document = document
				return resource
			},
		},
		{
			name: "access key secret reference",
			mutate: func(resource PolicyResource) PolicyResource {
				document := cloneMap(resource.Document)
				secretKeyRef := litestreamReplicaSecretKeyRef(document, "accessKeyID")
				secretKeyRef["name"] = "other-secret"
				resource.Document = document
				return resource
			},
		},
		{
			name: "access secret reference",
			mutate: func(resource PolicyResource) PolicyResource {
				document := cloneMap(resource.Document)
				secretKeyRef := litestreamReplicaSecretKeyRef(document, "secretAccessKey")
				secretKeyRef["key"] = "other-key"
				resource.Document = document
				return resource
			},
		},
	} {
		t.Run("rejects broken replica "+tc.name, func(t *testing.T) {
			mutated := replaceResource(baseInput.Resources, "LitestreamReplica", "app", "feed-reader-db-debug-source", tc.mutate)
			assertPolicyFails(t, evaluator, PolicyInput{
				Resources: mutated,
				Context:   policyContext("litestream"),
			}, "litestream-replica-must-match-storage-contract")
		})
	}

	t.Run("rejects an unwanted Litestream resource in the vcluster render", func(t *testing.T) {
		resources := append(append([]PolicyResource{}, baseInput.Resources...), PolicyResource{
			Source: "render:clusters/vcluster-app",
			Document: map[string]any{
				"apiVersion": "litestream.mytools.nakatanakatana.app/v1alpha1",
				"kind":       "Litestream",
				"metadata": map[string]any{
					"name":      "unwanted",
					"namespace": "feed-reader",
				},
			},
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: resources,
			Context:   policyContext("litestream"),
		}, "litestream-vcluster-must-not-contain-resources")
	})

	t.Run("rejects an unwanted Litestream CRD in the vcluster render", func(t *testing.T) {
		resources := append(append([]PolicyResource{}, baseInput.Resources...), PolicyResource{
			Source: "render:clusters/vcluster-app",
			Document: map[string]any{
				"apiVersion": "apiextensions.k8s.io/v1",
				"kind":       "CustomResourceDefinition",
				"metadata": map[string]any{
					"name": "litestreams.litestream.mytools.nakatanakatana.app",
				},
			},
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: resources,
			Context:   policyContext("litestream"),
		}, "litestream-vcluster-must-not-contain-resources")
	})

	t.Run("rejects an unwanted Litestream controller Deployment in the vcluster render", func(t *testing.T) {
		resources := append(append([]PolicyResource{}, baseInput.Resources...), PolicyResource{
			Source: "render:clusters/vcluster-app",
			Document: map[string]any{
				"apiVersion": "apps/v1",
				"kind":       "Deployment",
				"metadata": map[string]any{
					"name":      "litestream-controller",
					"namespace": "litestream-system",
				},
			},
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: resources,
			Context:   policyContextWithCommonPoliciesDisabled("litestream"),
		}, "litestream-vcluster-must-not-contain-resources")
	})

	t.Run("rejects stale Litestream debug ConfigMap wiring in the vcluster render", func(t *testing.T) {
		resources := append(append([]PolicyResource{}, baseInput.Resources...), PolicyResource{
			Source: "render:clusters/vcluster-app",
			Document: map[string]any{
				"apiVersion": "v1",
				"kind":       "ConfigMap",
				"metadata": map[string]any{
					"name":      "feed-reader-debug-config",
					"namespace": "feed-reader",
				},
				"data": map[string]any{
					"litestream.yml": "dbs: []",
				},
			},
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: resources,
			Context:   policyContextWithCommonPoliciesDisabled("litestream"),
		}, "litestream-vcluster-must-not-contain-resources")
	})

	t.Run("rejects exposed debug services", func(t *testing.T) {
		resources := append(append([]PolicyResource{}, baseInput.Resources...), PolicyResource{
			Source: "render:clusters/vcluster-app/feed-reader-debug/workload",
			Document: serviceDocument(
				"feed-reader-db-debug",
				"feed-reader",
				"ClusterIP",
			),
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: resources,
			Context:   policyContext("litestream"),
		}, "litestream-debug-workload-must-not-expose-service")
	})

	t.Run("rejects exposed debug ingresses", func(t *testing.T) {
		resources := append(append([]PolicyResource{}, baseInput.Resources...), PolicyResource{
			Source:   "render:clusters/vcluster-app/feed-reader-debug/workload",
			Document: ingressDocument("feed-reader-db-debug", "feed-reader", "feed-reader-db-debug"),
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: resources,
			Context:   policyContext("litestream"),
		}, "litestream-debug-workload-must-not-expose-ingress")
	})
}

func TestPCloudS3SemanticPolicies(t *testing.T) {
	evaluator := newTestPolicyEvaluator(t)

	renderedResources := mustRenderPolicyResources(t, "components/pcloud-s3")
	namespaceResources := mustLoadPolicyResources(t, repoPath("clusters", "home", "_system", "namespaces", "pcloud-s3.yaml"))

	baseInput := PolicyInput{
		Resources: appendPolicyResources(renderedResources, namespaceResources),
		Context:   policyContextWithFullContract("pcloud-s3"),
	}

	assertPolicyPasses(t, evaluator, baseInput)

	t.Run("rejects an empty full pcloud contract", func(t *testing.T) {
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: []PolicyResource{},
			Context:   policyContextWithFullContract("pcloud-s3"),
		}, "pcloud-must-include-resources")
	})

	t.Run("rejects a full pcloud contract with all target sources missing", func(t *testing.T) {
		mutated := replaceAllResourceSources(baseInput.Resources, "render:unrelated")
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContextWithFullContract("pcloud-s3"),
		}, "pcloud-must-include-resources")
	})

	t.Run("pcloud service rules ignore unrelated sources", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source:   "render:clusters/other-app",
				Document: serviceDocument("gateway", "pcloud-s3", "LoadBalancer"),
			}},
		})
	})

	t.Run("pcloud service rules reject near-match component sources", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source:   "render:components/pcloud-s3-other",
				Document: serviceDocument("gateway", "pcloud-s3", "LoadBalancer"),
			}},
		})
	})

	t.Run("pcloud workload rules ignore unrelated sources", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source: "render:clusters/other-app",
				Document: pcloudGatewayDeploymentDocument(map[string]any{
					"automountServiceAccountToken": true,
				}, map[string]any{
					"securityContext": map[string]any{
						"allowPrivilegeEscalation": true,
					},
				}),
			}},
		})
	})

	t.Run("pcloud ingress rules ignore unrelated sources", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source:   "render:clusters/other-app",
				Document: ingressDocument("gateway", "pcloud-s3", "gateway"),
			}},
			Context: policyContext("pcloud-s3"),
		})
	})

	t.Run("pcloud ingress rules ignore unrelated gateway relationships", func(t *testing.T) {
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: append(append([]PolicyResource{}, baseInput.Resources...), PolicyResource{
				Source:   "render:components/pcloud-s3",
				Document: ingressDocument("other", "pcloud-s3", "other-service"),
			}),
			Context: policyContext("pcloud-s3"),
		}, "pcloud-gateway-must-not-render-ingress")
	})

	for _, tc := range []struct {
		name         string
		kind         string
		ns           string
		nameToRemove string
	}{
		{name: "Namespace", kind: "Namespace", nameToRemove: "pcloud-s3"},
		{name: "Deployment", kind: "Deployment", ns: "pcloud-s3", nameToRemove: "rclone-s3-gateway"},
		{name: "Service", kind: "Service", ns: "pcloud-s3", nameToRemove: "gateway"},
		{name: "PVC", kind: "PersistentVolumeClaim", ns: "pcloud-s3", nameToRemove: "rclone-s3-cache"},
	} {
		t.Run("requires "+tc.name, func(t *testing.T) {
			mutated := removeResourceByName(baseInput.Resources, tc.kind, tc.ns, tc.nameToRemove)
			assertPolicyFails(t, evaluator, PolicyInput{
				Resources: mutated,
				Context:   policyContext("pcloud-s3"),
			}, "pcloud-must-include-resources")
		})
	}

	t.Run("rejects gateway services that are not clusterip", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Service", "pcloud-s3", "gateway", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			document["spec"].(map[string]any)["type"] = "LoadBalancer"
			resource.Document = document
			return resource
		})

		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("pcloud-s3"),
		}, "service-must-use-clusterip")
	})

	t.Run("rejects a gateway service with the wrong port", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Service", "pcloud-s3", "gateway", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			ports := document["spec"].(map[string]any)["ports"].([]any)
			ports[0].(map[string]any)["port"] = 80
			resource.Document = document
			return resource
		})

		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("pcloud-s3"),
		}, "pcloud-gateway-service-must-expose-s3-port")
	})

	t.Run("rejects a gateway service with the wrong selector", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Service", "pcloud-s3", "gateway", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			document["spec"].(map[string]any)["selector"].(map[string]any)["app"] = "other"
			resource.Document = document
			return resource
		})

		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("pcloud-s3"),
		}, "pcloud-gateway-service-must-select-gateway")
	})

	t.Run("rejects an externally exposed gateway", func(t *testing.T) {
		resources := append(append([]PolicyResource{}, baseInput.Resources...), PolicyResource{
			Source:   "render:components/pcloud-s3",
			Document: ingressDocument("gateway", "pcloud-s3", "gateway"),
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: resources,
			Context:   policyContext("pcloud-s3"),
		}, "pcloud-gateway-must-not-render-ingress")
	})

	t.Run("rejects an externally exposed gateway through defaultBackend", func(t *testing.T) {
		resources := append(append([]PolicyResource{}, baseInput.Resources...), PolicyResource{
			Source:   "render:components/pcloud-s3",
			Document: ingressDefaultBackendDocument("gateway-default", "pcloud-s3", "gateway"),
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: resources,
			Context:   policyContext("pcloud-s3"),
		}, "pcloud-gateway-must-not-render-ingress")
	})

	t.Run("rejects a gateway with more than one replica", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Deployment", "pcloud-s3", "rclone-s3-gateway", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			document["spec"].(map[string]any)["replicas"] = 2
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("pcloud-s3"),
		}, "pcloud-gateway-must-run-single-replica")
	})

	t.Run("rejects a gateway that does not recreate during updates", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Deployment", "pcloud-s3", "rclone-s3-gateway", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			document["spec"].(map[string]any)["strategy"].(map[string]any)["type"] = "RollingUpdate"
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("pcloud-s3"),
		}, "pcloud-gateway-must-recreate")
	})

	t.Run("rejects a gateway with the wrong pod fsGroup", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Deployment", "pcloud-s3", "rclone-s3-gateway", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
			podSpec["securityContext"].(map[string]any)["fsGroup"] = 1008
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: policyContext("pcloud-s3")}, "pcloud-gateway-must-use-pod-security-context")
	})

	for _, tc := range []struct {
		name   string
		mutate func(map[string]any)
	}{
		{
			name: "missing listen address",
			mutate: func(document map[string]any) {
				podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
				container := podSpec["containers"].([]any)[0].(map[string]any)
				container["args"] = []any{"serve", "s3", "pcloud:buckets"}
			},
		},
		{
			name: "wrong pCloud hostname",
			mutate: func(document map[string]any) {
				podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
				container := podSpec["containers"].([]any)[0].(map[string]any)
				for _, value := range container["env"].([]any) {
					entry := value.(map[string]any)
					if entry["name"] == "RCLONE_CONFIG_PCLOUD_HOSTNAME" {
						entry["value"] = "example.invalid"
					}
				}
			},
		},
		{
			name: "missing cache size limit",
			mutate: func(document map[string]any) {
				podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
				container := podSpec["containers"].([]any)[0].(map[string]any)
				args := container["args"].([]any)
				filtered := make([]any, 0, len(args))
				for _, arg := range args {
					if arg != "--vfs-cache-max-size=45Gi" {
						filtered = append(filtered, arg)
					}
				}
				container["args"] = filtered
			},
		},
	} {
		t.Run("rejects a gateway with "+tc.name, func(t *testing.T) {
			mutated := replaceResource(baseInput.Resources, "Deployment", "pcloud-s3", "rclone-s3-gateway", func(resource PolicyResource) PolicyResource {
				document := cloneMap(resource.Document)
				tc.mutate(document)
				resource.Document = document
				return resource
			})
			assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: policyContext("pcloud-s3")}, "pcloud-gateway-must-match-runtime-contract")
		})
	}

	t.Run("rejects a gateway without cache volume wiring", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Deployment", "pcloud-s3", "rclone-s3-gateway", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			podSpec := document["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
			delete(podSpec, "volumes")
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("pcloud-s3"),
		}, "pcloud-gateway-must-wire-cache")
	})

	t.Run("rejects an unprotected cache claim", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "PersistentVolumeClaim", "pcloud-s3", "rclone-s3-cache", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			delete(document["metadata"].(map[string]any), "annotations")
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("pcloud-s3"),
		}, "pcloud-cache-pvc-must-protect-from-prune")
	})

	t.Run("rejects an unprotected pcloud namespace", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Namespace", "", "pcloud-s3", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			delete(document["metadata"].(map[string]any), "annotations")
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("pcloud-s3"),
		}, "pcloud-namespace-must-protect-from-prune")
	})
}

func TestExternalSecretRateLimitPolicy(t *testing.T) {
	evaluator := newTestPolicyEvaluator(t)

	resources := mustLoadPolicyResources(t, repoPath("clusters", "home", "configs", "external-secrets"))
	assertPolicyPasses(t, evaluator, PolicyInput{
		Resources: resources,
		Context:   policyContext("external-secrets"),
	})

	for _, tc := range []struct {
		name      string
		namespace string
	}{
		{name: "rclone-s3-credentials", namespace: "pcloud-s3"},
		{name: "neon-s3-credentials", namespace: "database"},
		{name: "feed-reader-storage", namespace: "app"},
	} {
		t.Run("requires "+tc.namespace+"/"+tc.name, func(t *testing.T) {
			mutated := removeResourceByName(resources, "ExternalSecret", tc.namespace, tc.name)
			assertPolicyFails(t, evaluator, PolicyInput{
				Resources: mutated,
				Context:   policyContext("external-secrets"),
			}, "external-secret-must-include-required-resources")
		})
	}

	t.Run("requires the configured ClusterSecretStore", func(t *testing.T) {
		mutated := removeResourceByKindName(resources, "ClusterSecretStore", "", "1password-sdk")
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   policyContext("external-secrets"),
		}, "cluster-secret-store-must-exist")
	})

	t.Run("external secret policies ignore unrelated sources", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source: "tests/unscoped/external-secret.yaml",
				Document: externalSecretDocument(
					"unscoped-secret",
					"default",
					"1h",
				),
			}},
		})
	})

	t.Run("external secret policies reject near-match source paths", func(t *testing.T) {
		assertPolicyPasses(t, evaluator, PolicyInput{
			Resources: []PolicyResource{{
				Source: "render:clusters/home/configs/notclusters/home/configs/external-secrets/near-match.yaml",
				Document: externalSecretDocument(
					"near-match-secret",
					"default",
					"1h",
				),
			}},
		})
	})
}

func TestFluxSemanticPolicies(t *testing.T) {
	evaluator := newTestPolicyEvaluator(t)

	baseInput := PolicyInput{
		Resources: appendPolicyResources(
			mustLoadCanonicalPolicyResources(t, "clusters/home/controllers/kubeblocks-crds.yaml"),
			mustLoadCanonicalPolicyResources(t, "clusters/home/controllers/kubeblocks.yaml"),
			mustLoadCanonicalPolicyResources(t, "clusters/home/configs/_next.yaml"),
			mustLoadCanonicalPolicyResources(t, "clusters/home/controllers/_next.yaml"),
			mustLoadCanonicalPolicyResources(t, "clusters/home/resources/_next.yaml"),
			mustLoadCanonicalPolicyResources(t, "clusters/home/controllers/litestream-controller.yaml"),
			mustLoadCanonicalPolicyResources(t, "clusters/home/resources/vcluster-app-sync.yaml"),
		),
	}

	assertPolicyPasses(t, evaluator, baseInput)

	testCases := []struct {
		name       string
		policyName string
		mutate     func([]PolicyResource) []PolicyResource
	}{
		{
			name:       "kubeblocks depends on kubeblocks crds",
			policyName: "flux-kubeblocks-must-depend-on-crds",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "kubeblocks", func(document map[string]any) {
					spec := document["spec"].(map[string]any)
					delete(spec, "dependsOn")
				})
			},
		},
		{
			name:       "kubeblocks crds waits for readiness",
			policyName: "flux-kubeblocks-crds-must-wait",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "kubeblocks-crds", func(document map[string]any) {
					document["spec"].(map[string]any)["wait"] = false
				})
			},
		},
		{
			name:       "kubeblocks waits for readiness",
			policyName: "flux-kubeblocks-must-wait",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "kubeblocks", func(document map[string]any) {
					document["spec"].(map[string]any)["wait"] = false
				})
			},
		},
		{
			name:       "kubeblocks has a bounded reconciliation timeout",
			policyName: "flux-kubeblocks-must-have-timeout",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "kubeblocks", func(document map[string]any) {
					delete(document["spec"].(map[string]any), "timeout")
				})
			},
		},
		{
			name:       "litestream controller depends on cert manager",
			policyName: "flux-litestream-controller-must-depend-on-cert-manager",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "litestream-controller", func(document map[string]any) {
					delete(document["spec"].(map[string]any), "dependsOn")
				})
			},
		},
		{
			name:       "vcluster app sync depends on cluster resources",
			policyName: "flux-vcluster-app-sync-must-depend-on-cluster-resources",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return replaceResource(resources, "Kustomization", "app", "vcluster-app-sync", func(resource PolicyResource) PolicyResource {
					document := cloneMap(resource.Document)
					document["spec"].(map[string]any)["dependsOn"] = []any{}
					resource.Document = document
					return resource
				})
			},
		},
		{
			name:       "cluster controllers depend on cluster configs",
			policyName: "flux-cluster-controllers-must-depend-on-configs",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "cluster-controllers", func(document map[string]any) {
					document["spec"].(map[string]any)["dependsOn"] = []any{
						map[string]any{"name": "other-configs"},
					}
				})
			},
		},
		{
			name:       "cluster controllers health check kubeblocks",
			policyName: "flux-cluster-controllers-must-health-check-kubeblocks",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "cluster-controllers", func(document map[string]any) {
					document["spec"].(map[string]any)["healthChecks"] = []any{
						map[string]any{
							"apiVersion": "kustomize.toolkit.fluxcd.io/v1",
							"kind":       "Kustomization",
							"name":       "other-controller",
							"namespace":  "flux-system",
						},
					}
				})
			},
		},
		{
			name:       "cluster resources depend on cluster controllers",
			policyName: "flux-cluster-resources-must-depend-on-controllers",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "cluster-resources", func(document map[string]any) {
					delete(document["spec"].(map[string]any), "dependsOn")
				})
			},
		},
		{
			name:       "cluster resources health check litestream",
			policyName: "flux-cluster-resources-must-health-check-litestream",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "cluster-resources", func(document map[string]any) {
					document["spec"].(map[string]any)["healthChecks"] = []any{
						map[string]any{
							"apiVersion": "litestream.mytools.nakatanakatana.app/v1alpha1",
							"kind":       "Litestream",
							"name":       "other-litestream",
							"namespace":  "app",
						},
					}
				})
			},
		},
		{
			name:       "cluster vcluster depends on cluster resources",
			policyName: "flux-cluster-vcluster-must-depend-on-resources",
			mutate: func(resources []PolicyResource) []PolicyResource {
				return mutateFluxKustomization(resources, "cluster-vcluster", func(document map[string]any) {
					document["spec"].(map[string]any)["dependsOn"] = []any{
						map[string]any{"name": "other-resources"},
					}
				})
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			assertPolicyFails(t, evaluator, PolicyInput{Resources: tc.mutate(baseInput.Resources)}, tc.policyName)
		})
	}

	t.Run("vcluster app sync requires an explicit flux namespace", func(t *testing.T) {
		mutated := replaceResource(baseInput.Resources, "Kustomization", "app", "vcluster-app-sync", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			document["spec"].(map[string]any)["dependsOn"] = []any{
				map[string]any{"name": "cluster-resources"},
			}
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated}, "flux-vcluster-app-sync-must-depend-on-cluster-resources")
	})
}

func TestKubeBlocksNeonSemanticPolicies(t *testing.T) {
	runKubeBlocksNeonSemanticPolicies(t)
}

func assertPolicyPasses(t *testing.T, evaluator *PolicyEvaluator, input PolicyInput) {
	t.Helper()

	violations, err := evaluator.Evaluate(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	if len(violations) != 0 {
		t.Fatalf("unexpected policy violations:\n%s", FormatPolicyViolations(violations))
	}
}

func assertPolicyFails(t *testing.T, evaluator *PolicyEvaluator, input PolicyInput, policyName string) {
	t.Helper()

	violations, err := evaluator.Evaluate(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	for _, violation := range violations {
		if violation.Policy == policyName {
			return
		}
	}
	if len(violations) == 0 {
		t.Fatalf("expected policy %q to fail, but no violations were reported", policyName)
	}
	t.Fatalf("expected policy %q to fail, got:\n%s", policyName, FormatPolicyViolations(violations))
}

func assertPolicyFailsForResources(t *testing.T, evaluator *PolicyEvaluator, input PolicyInput, policyName string, expectedResources ...string) {
	t.Helper()

	violations, err := evaluator.Evaluate(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	found := make(map[string]bool, len(expectedResources))
	for _, violation := range violations {
		if violation.Policy == policyName {
			found[violation.Resource] = true
		}
	}
	for _, expectedResource := range expectedResources {
		if !found[expectedResource] {
			t.Fatalf("expected policy %q to report resource %q, got:\n%s", policyName, expectedResource, FormatPolicyViolations(violations))
		}
	}
}

func newTestPolicyEvaluator(t *testing.T) *PolicyEvaluator {
	t.Helper()

	evaluator, err := NewPolicyEvaluator()
	if err != nil {
		t.Fatal(err)
	}
	return evaluator
}

func mustRenderPolicyResources(t *testing.T, relativePath string) []PolicyResource {
	t.Helper()

	resources, err := renderKustomization(context.Background(), "..", relativePath)
	if err != nil {
		t.Fatal(err)
	}
	return resources
}

func mustLoadPolicyResources(t *testing.T, path string) []PolicyResource {
	t.Helper()

	resources, err := loadPolicyResources(path)
	if err != nil {
		t.Fatal(err)
	}
	return resources
}

func mustLoadCanonicalPolicyResources(t *testing.T, source string) []PolicyResource {
	t.Helper()

	resources := mustLoadPolicyResources(t, repoPath(source))
	for index := range resources {
		resources[index].Source = source
	}
	return resources
}

func mutateFluxKustomization(resources []PolicyResource, name string, mutate func(map[string]any)) []PolicyResource {
	return replaceResource(resources, "Kustomization", "flux-system", name, func(resource PolicyResource) PolicyResource {
		document := cloneMap(resource.Document)
		mutate(document)
		resource.Document = document
		return resource
	})
}

func policyContext(scope string) map[string]any {
	return map[string]any{"policyScope": scope}
}

func policyContextWithFullContract(scope string) map[string]any {
	return map[string]any{
		"policyScope":  scope,
		"fullContract": true,
	}
}

func policyContextWithCommonPoliciesDisabled(scope string) map[string]any {
	return map[string]any{
		"policyScope":                      scope,
		"skipCommonPoliciesForMixedRender": true,
	}
}

func policyContextWithCommonPoliciesDisabledAndFullContract(scope string) map[string]any {
	return map[string]any{
		"policyScope":                      scope,
		"fullContract":                     true,
		"skipCommonPoliciesForMixedRender": true,
	}
}

func repoPath(parts ...string) string {
	return filepath.Join(append([]string{".."}, parts...)...)
}

func appendPolicyResources(resourceSets ...[]PolicyResource) []PolicyResource {
	var combined []PolicyResource
	for _, resources := range resourceSets {
		combined = append(combined, resources...)
	}
	return combined
}

func removeResourceByName(resources []PolicyResource, kind, namespace, name string) []PolicyResource {
	filtered := make([]PolicyResource, 0, len(resources))
	for _, resource := range resources {
		document := resource.Document
		if document["kind"] == kind &&
			resourceName(document) == name &&
			resourceNamespace(document) == namespace {
			continue
		}
		filtered = append(filtered, resource)
	}
	return filtered
}

func removeResourceByKindName(resources []PolicyResource, kind, namespace, name string) []PolicyResource {
	filtered := make([]PolicyResource, 0, len(resources))
	matched := false
	for _, resource := range resources {
		document := resource.Document
		if document["kind"] == kind &&
			resourceName(document) == name &&
			(namespace == "" || resourceNamespace(document) == namespace) {
			matched = true
			continue
		}
		filtered = append(filtered, resource)
	}
	if !matched {
		panic("resource not found")
	}
	return filtered
}

func replaceAllResourceSources(resources []PolicyResource, source string) []PolicyResource {
	replaced := make([]PolicyResource, len(resources))
	copy(replaced, resources)
	for index := range replaced {
		replaced[index].Source = source
	}
	return replaced
}

func replaceResource(resources []PolicyResource, kind, namespace, name string, mutate func(PolicyResource) PolicyResource) []PolicyResource {
	replaced := make([]PolicyResource, 0, len(resources))
	matched := false
	for _, resource := range resources {
		document := resource.Document
		if document["kind"] == kind &&
			resourceName(document) == name &&
			resourceNamespace(document) == namespace {
			replaced = append(replaced, mutate(resource))
			matched = true
			continue
		}
		replaced = append(replaced, resource)
	}
	if !matched {
		panic("resource not found")
	}
	return replaced
}

func matchingResources(resources []PolicyResource, kind, namespace, name string) []PolicyResource {
	matches := make([]PolicyResource, 0, 1)
	for _, resource := range resources {
		document := resource.Document
		if document["kind"] == kind &&
			resourceName(document) == name &&
			resourceNamespace(document) == namespace {
			matches = append(matches, resource)
		}
	}
	if len(matches) == 0 {
		panic("resource not found")
	}
	return matches
}

func cloneMap(source map[string]any) map[string]any {
	cloned := make(map[string]any, len(source))
	for key, value := range source {
		cloned[key] = cloneValue(value)
	}
	return cloned
}

func cloneSlice(source []any) []any {
	cloned := make([]any, len(source))
	for index, value := range source {
		cloned[index] = cloneValue(value)
	}
	return cloned
}

func cloneValue(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		return cloneMap(typed)
	case []any:
		return cloneSlice(typed)
	default:
		return typed
	}
}

func resourceName(document map[string]any) string {
	metadata, _ := document["metadata"].(map[string]any)
	name, _ := metadata["name"].(string)
	return name
}

func resourceNamespace(document map[string]any) string {
	metadata, _ := document["metadata"].(map[string]any)
	namespace, _ := metadata["namespace"].(string)
	return namespace
}

func litestreamReplicaS3(document map[string]any) map[string]any {
	return document["spec"].(map[string]any)["replica"].(map[string]any)["s3"].(map[string]any)
}

func litestreamReplicaSecretKeyRef(document map[string]any, field string) map[string]any {
	credentials := litestreamReplicaS3(document)["credentials"].(map[string]any)
	return credentials[field].(map[string]any)["secretKeyRef"].(map[string]any)
}

func deploymentDocument(name, namespace string, envValues map[string]string, envEntries []map[string]any) map[string]any {
	env := make([]any, 0, len(envValues)+len(envEntries))
	for key, value := range envValues {
		env = append(env, map[string]any{
			"name":  key,
			"value": value,
		})
	}
	for _, entry := range envEntries {
		env = append(env, entry)
	}

	container := map[string]any{
		"name":  "app",
		"image": envValues["image"],
	}
	if container["image"] == "" {
		container["image"] = "nginx:1.27.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	}
	if len(env) > 0 {
		container["env"] = env
	}

	return map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]any{
			"name":      name,
			"namespace": namespace,
		},
		"spec": map[string]any{
			"selector": map[string]any{
				"matchLabels": map[string]any{
					"app": name,
				},
			},
			"template": map[string]any{
				"metadata": map[string]any{
					"labels": map[string]any{
						"app": name,
					},
				},
				"spec": map[string]any{
					"containers": []any{container},
				},
			},
		},
	}
}

func deploymentWithInitContainer(name, namespace string, initContainerOverrides map[string]any) map[string]any {
	document := deploymentDocument(name, namespace, nil, nil)

	initContainer := map[string]any{
		"name":  "init",
		"image": "busybox:1.36.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	}
	for key, value := range initContainerOverrides {
		initContainer[key] = value
	}

	spec := document["spec"].(map[string]any)
	template := spec["template"].(map[string]any)
	podSpec := template["spec"].(map[string]any)
	podSpec["initContainers"] = []any{initContainer}

	return document
}

func pcloudGatewayDeploymentDocument(podSpecOverrides map[string]any, containerOverrides map[string]any) map[string]any {
	container := map[string]any{
		"name":  "rclone",
		"image": "rclone/rclone@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"args": []any{
			"serve",
			"s3",
			"pcloud:buckets",
			"--addr=:8080",
			"--log-level=NOTICE",
			"--vfs-cache-mode=writes",
			"--cache-dir=/cache",
			"--dir-cache-time=1h",
			"--poll-interval=5m",
			"--vfs-cache-max-size=45Gi",
			"--vfs-cache-min-free-space=2Gi",
			"--vfs-cache-max-age=24h",
			"--vfs-cache-poll-interval=1m",
			"--vfs-write-back=5s",
			"--transfers=2",
			"--buffer-size=16Mi",
		},
		"env": []any{
			map[string]any{
				"name":  "RCLONE_CONFIG_PCLOUD_TYPE",
				"value": "pcloud",
			},
			map[string]any{
				"name":  "RCLONE_CONFIG_PCLOUD_HOSTNAME",
				"value": "api.pcloud.com",
			},
			map[string]any{
				"name": "RCLONE_CONFIG_PCLOUD_TOKEN",
				"valueFrom": map[string]any{
					"secretKeyRef": map[string]any{
						"name": "rclone-s3-credentials",
						"key":  "PCLOUD_TOKEN",
					},
				},
			},
			map[string]any{
				"name": "RCLONE_AUTH_KEY",
				"valueFrom": map[string]any{
					"secretKeyRef": map[string]any{
						"name": "rclone-s3-credentials",
						"key":  "RCLONE_AUTH_KEY",
					},
				},
			},
		},
		"securityContext": map[string]any{
			"allowPrivilegeEscalation": false,
			"readOnlyRootFilesystem":   true,
			"capabilities": map[string]any{
				"drop": []any{"ALL"},
			},
		},
		"volumeMounts": []any{map[string]any{
			"name":      "cache",
			"mountPath": "/cache",
		}},
	}
	for key, value := range containerOverrides {
		container[key] = value
	}

	podSpec := map[string]any{
		"automountServiceAccountToken": false,
		"securityContext": map[string]any{
			"runAsNonRoot":        true,
			"runAsUser":           1009,
			"runAsGroup":          1009,
			"fsGroup":             1009,
			"fsGroupChangePolicy": "OnRootMismatch",
			"seccompProfile": map[string]any{
				"type": "RuntimeDefault",
			},
		},
		"containers": []any{container},
		"volumes": []any{map[string]any{
			"name": "cache",
			"persistentVolumeClaim": map[string]any{
				"claimName": "rclone-s3-cache",
			},
		}},
	}
	for key, value := range podSpecOverrides {
		podSpec[key] = value
	}

	return map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]any{
			"name":      "rclone-s3-gateway",
			"namespace": "pcloud-s3",
		},
		"spec": map[string]any{
			"replicas": 1,
			"strategy": map[string]any{
				"type": "Recreate",
			},
			"selector": map[string]any{
				"matchLabels": map[string]any{
					"app": "rclone-s3-gateway",
				},
			},
			"template": map[string]any{
				"metadata": map[string]any{
					"labels": map[string]any{
						"app": "rclone-s3-gateway",
					},
				},
				"spec": podSpec,
			},
		},
	}
}

func pvcDocument(name, namespace, storageClassName, storage string) map[string]any {
	return map[string]any{
		"apiVersion": "v1",
		"kind":       "PersistentVolumeClaim",
		"metadata": map[string]any{
			"name":      name,
			"namespace": namespace,
			"annotations": map[string]any{
				"kustomize.toolkit.fluxcd.io/prune": "disabled",
			},
		},
		"spec": map[string]any{
			"storageClassName": storageClassName,
			"accessModes":      []any{"ReadWriteOnce"},
			"resources": map[string]any{
				"requests": map[string]any{
					"storage": storage,
				},
			},
		},
	}
}

func serviceDocument(name, namespace, serviceType string) map[string]any {
	return map[string]any{
		"apiVersion": "v1",
		"kind":       "Service",
		"metadata": map[string]any{
			"name":      name,
			"namespace": namespace,
		},
		"spec": map[string]any{
			"type": serviceType,
			"selector": map[string]any{
				"app": "rclone-s3-gateway",
			},
			"ports": []any{map[string]any{
				"name":       "http",
				"port":       8080,
				"targetPort": "s3",
			}},
		},
	}
}

func ingressDocument(name, namespace, serviceName string) map[string]any {
	return map[string]any{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "Ingress",
		"metadata": map[string]any{
			"name":      name,
			"namespace": namespace,
		},
		"spec": map[string]any{
			"rules": []any{map[string]any{
				"host": name,
				"http": map[string]any{
					"paths": []any{map[string]any{
						"path":     "/",
						"pathType": "Prefix",
						"backend": map[string]any{
							"service": map[string]any{
								"name": serviceName,
								"port": map[string]any{
									"number": 8080,
								},
							},
						},
					}},
				},
			}},
		},
	}
}

func ingressDefaultBackendDocument(name, namespace, serviceName string) map[string]any {
	return map[string]any{
		"apiVersion": "networking.k8s.io/v1",
		"kind":       "Ingress",
		"metadata": map[string]any{
			"name":      name,
			"namespace": namespace,
		},
		"spec": map[string]any{
			"defaultBackend": map[string]any{
				"service": map[string]any{
					"name": serviceName,
					"port": map[string]any{
						"number": 8080,
					},
				},
			},
		},
	}
}

func externalSecretDocument(name, namespace, refreshInterval string) map[string]any {
	return map[string]any{
		"apiVersion": "external-secrets.io/v1",
		"kind":       "ExternalSecret",
		"metadata": map[string]any{
			"name":      name,
			"namespace": namespace,
		},
		"spec": map[string]any{
			"refreshInterval": refreshInterval,
			"secretStoreRef": map[string]any{
				"kind": "ClusterSecretStore",
				"name": "1password-sdk",
			},
			"target": map[string]any{
				"name":           name,
				"creationPolicy": "Owner",
			},
			"data": []any{map[string]any{
				"secretKey": "token",
				"remoteRef": map[string]any{
					"key": "example/token",
				},
			}},
		},
	}
}
