package main

import "testing"

func TestKubeBlocksCorePolicies(t *testing.T) {
	evaluator := newTestPolicyEvaluator(t)
	resources := mustLoadPolicyResources(t, repoPath("components", "kubeblocks", "release.yaml"))
	baseInput := PolicyInput{
		Resources: resources,
		Context:   policyContext("kubeblocks"),
	}
	assertPolicyPasses(t, evaluator, baseInput)

	t.Run("requires addon controller to remain disabled", func(t *testing.T) {
		mutated := replaceResource(resources, "HelmRelease", "kb-system", "kubeblocks", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			spec := cloneMap(document["spec"].(map[string]any))
			values := cloneMap(spec["values"].(map[string]any))
			addonController := cloneMap(values["addonController"].(map[string]any))
			addonController["enabled"] = true
			values["addonController"] = addonController
			spec["values"] = values
			document["spec"] = spec
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   baseInput.Context,
		}, "kubeblocks-addon-controller-must-remain-disabled")
	})

	t.Run("requires automatic addons to remain disabled", func(t *testing.T) {
		mutated := replaceResource(resources, "HelmRelease", "kb-system", "kubeblocks", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			spec := cloneMap(document["spec"].(map[string]any))
			values := cloneMap(spec["values"].(map[string]any))
			values["autoInstalledAddons"] = []any{"postgresql"}
			spec["values"] = values
			document["spec"] = spec
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mutated,
			Context:   baseInput.Context,
		}, "kubeblocks-auto-installed-addons-must-remain-empty")
	})
}

func TestKubeBlocksGenericPolicies(t *testing.T) {
	evaluator := newTestPolicyEvaluator(t)

	testCases := []struct {
		name       string
		resource   PolicyResource
		policyName string
	}{
		{
			name: "rejects an undigested ComponentDefinition runtime image",
			resource: PolicyResource{
				Source: "tests/inline/kubeblocks-generic.yaml",
				Document: map[string]any{
					"apiVersion": "apps.kubeblocks.io/v1",
					"kind":       "ComponentDefinition",
					"metadata":   map[string]any{"name": "generic-component"},
					"spec": map[string]any{
						"runtime": map[string]any{
							"containers": []any{map[string]any{
								"name":  "server",
								"image": "example.invalid/kubeblocks:1.0",
							}},
						},
					},
				},
			},
			policyName: "kubeblocks-image-must-be-digest-pinned",
		},
		{
			name: "rejects a latest ComponentDefinition runtime image",
			resource: PolicyResource{
				Source: "tests/inline/kubeblocks-generic.yaml",
				Document: map[string]any{
					"apiVersion": "apps.kubeblocks.io/v1",
					"kind":       "ComponentDefinition",
					"metadata":   map[string]any{"name": "generic-component"},
					"spec": map[string]any{
						"runtime": map[string]any{
							"containers": []any{map[string]any{
								"name":  "server",
								"image": "example.invalid/kubeblocks:latest",
							}},
						},
					},
				},
			},
			policyName: "kubeblocks-image-must-not-use-latest",
		},
		{
			name: "rejects an undigested ComponentVersion release image",
			resource: PolicyResource{
				Source: "tests/inline/kubeblocks-generic.yaml",
				Document: map[string]any{
					"apiVersion": "apps.kubeblocks.io/v1",
					"kind":       "ComponentVersion",
					"metadata":   map[string]any{"name": "generic-component"},
					"spec": map[string]any{
						"releases": []any{map[string]any{
							"images": map[string]any{"server": "example.invalid/kubeblocks:1.0"},
						}},
					},
				},
			},
			policyName: "kubeblocks-image-must-be-digest-pinned",
		},
		{
			name: "rejects a latest ComponentVersion release image",
			resource: PolicyResource{
				Source: "tests/inline/kubeblocks-generic.yaml",
				Document: map[string]any{
					"apiVersion": "apps.kubeblocks.io/v1",
					"kind":       "ComponentVersion",
					"metadata":   map[string]any{"name": "generic-component"},
					"spec": map[string]any{
						"releases": []any{map[string]any{
							"images": map[string]any{"server": "example.invalid/kubeblocks:latest"},
						}},
					},
				},
			},
			policyName: "kubeblocks-image-must-not-use-latest",
		},
		{
			name: "rejects a ComponentVersion release with changes",
			resource: PolicyResource{
				Source: "tests/inline/kubeblocks-generic.yaml",
				Document: map[string]any{
					"apiVersion": "apps.kubeblocks.io/v1",
					"kind":       "ComponentVersion",
					"metadata":   map[string]any{"name": "generic-component"},
					"spec": map[string]any{
						"releases": []any{map[string]any{
							"images":  map[string]any{"server": "example.invalid/kubeblocks:1.0@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
							"changes": []any{"unexpected change"},
						}},
					},
				},
			},
			policyName: "kubeblocks-component-version-must-not-retain-changes",
		},
		{
			name: "rejects a destructive Cluster termination policy",
			resource: PolicyResource{
				Source: "tests/inline/kubeblocks-generic.yaml",
				Document: map[string]any{
					"apiVersion": "apps.kubeblocks.io/v1",
					"kind":       "Cluster",
					"metadata":   map[string]any{"name": "generic-cluster"},
					"spec":       map[string]any{"terminationPolicy": "WipeOut"},
				},
			},
			policyName: "kubeblocks-cluster-must-not-use-wipeout",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			assertPolicyFails(t, evaluator, PolicyInput{
				Resources: []PolicyResource{tc.resource},
				Context:   policyContext("kubeblocks"),
			}, tc.policyName)
		})
	}
}
