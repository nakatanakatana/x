package main

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestWriteKustomizationForHelmRelease(t *testing.T) {
	t.Parallel()

	tempDir := t.TempDir()
	helmReleasePath := filepath.Join(tempDir, "helm-release.yaml")
	resourcePath := filepath.Join(tempDir, "nested", "component-versions-test.yaml")
	destinationPath := filepath.Join(tempDir, "generated", "kustomization.yaml")

	document := testHelmReleaseDocument()
	writeYAMLDocument(t, helmReleasePath, document)

	if err := writeKustomizationForHelmRelease(helmReleasePath, resourcePath, destinationPath); err != nil {
		t.Fatal(err)
	}

	generated := readYAMLDocument(t, destinationPath)
	resources, ok := generated["resources"].([]any)
	if !ok {
		t.Fatalf("generated resources = %#v, want a YAML sequence", generated["resources"])
	}
	if want := []any{filepath.Base(resourcePath)}; !reflect.DeepEqual(resources, want) {
		t.Fatalf("generated resources = %#v, want %#v", resources, want)
	}

	wantPatches := helmReleasePatches(t, document)
	gotPatches, ok := generated["patches"].([]any)
	if !ok {
		t.Fatalf("generated patches = %#v, want a YAML sequence", generated["patches"])
	}
	if !reflect.DeepEqual(gotPatches, wantPatches) {
		t.Fatalf("generated patches = %#v, want %#v", gotPatches, wantPatches)
	}
}

func TestWriteKustomizationForHelmReleaseRejectsMissingOrDuplicateComponentVersionTarget(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name       string
		mutate     func([]any) []any
		errorMatch string
	}{
		{
			name: "missing target",
			mutate: func(patches []any) []any {
				return patches[:1]
			},
			errorMatch: "exactly one ComponentVersion patch target",
		},
		{
			name: "duplicate target",
			mutate: func(patches []any) []any {
				return append(patches, cloneValue(patches[1]))
			},
			errorMatch: "exactly one ComponentVersion patch target",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			document := testHelmReleaseDocument()
			setHelmReleasePatches(document, tc.mutate(helmReleasePatches(t, document)))
			tempDir := t.TempDir()
			helmReleasePath := filepath.Join(tempDir, "helm-release.yaml")
			destinationPath := filepath.Join(tempDir, "kustomization.yaml")
			writeYAMLDocument(t, helmReleasePath, document)

			err := writeKustomizationForHelmRelease(helmReleasePath, "component-versions-test.yaml", destinationPath)
			if err == nil {
				t.Fatal("writeKustomizationForHelmRelease succeeded, want error")
			}
			if !strings.Contains(err.Error(), tc.errorMatch) {
				t.Fatalf("error %q does not contain %q", err, tc.errorMatch)
			}
		})
	}
}

func TestWriteKustomizationForHelmReleaseRejectsMultipleYAMLDocuments(t *testing.T) {
	t.Parallel()

	tempDir := t.TempDir()
	helmReleasePath := filepath.Join(tempDir, "helm-release.yaml")
	destinationPath := filepath.Join(tempDir, "kustomization.yaml")
	writeYAMLDocuments(t, helmReleasePath, []map[string]any{
		testHelmReleaseDocument(),
		testHelmReleaseDocument(),
	})

	err := writeKustomizationForHelmRelease(helmReleasePath, "component-versions-test.yaml", destinationPath)
	if err == nil {
		t.Fatal("writeKustomizationForHelmRelease succeeded, want error")
	}
	if !strings.Contains(err.Error(), "multiple YAML documents") {
		t.Fatalf("error %q does not identify multiple YAML documents", err)
	}
}

func TestWriteKustomizationForHelmReleaseRejectsMultiplePostRenderers(t *testing.T) {
	t.Parallel()

	document := testHelmReleaseDocument()
	spec := document["spec"].(map[string]any)
	postRenderers := cloneSlice(spec["postRenderers"].([]any))
	spec["postRenderers"] = append(postRenderers, cloneValue(postRenderers[0]))

	tempDir := t.TempDir()
	helmReleasePath := filepath.Join(tempDir, "helm-release.yaml")
	destinationPath := filepath.Join(tempDir, "kustomization.yaml")
	writeYAMLDocument(t, helmReleasePath, document)

	err := writeKustomizationForHelmRelease(helmReleasePath, "component-versions-test.yaml", destinationPath)
	if err == nil {
		t.Fatal("writeKustomizationForHelmRelease succeeded, want error")
	}
	if !strings.Contains(err.Error(), "multiple post-renderers") {
		t.Fatalf("error %q does not identify multiple post-renderers", err)
	}
}

func TestWriteKustomizationForHelmReleaseRejectsMissingSemanticSecurityContextPatch(t *testing.T) {
	t.Parallel()

	document := testHelmReleaseDocument()
	patches := helmReleasePatches(t, document)
	setHelmReleasePatches(document, patches[:4])

	tempDir := t.TempDir()
	helmReleasePath := filepath.Join(tempDir, "helm-release.yaml")
	destinationPath := filepath.Join(tempDir, "kustomization.yaml")
	writeYAMLDocument(t, helmReleasePath, document)

	err := writeKustomizationForHelmRelease(helmReleasePath, "component-definitions-test.yaml", destinationPath)
	if err == nil {
		t.Fatal("writeKustomizationForHelmRelease succeeded, want error")
	}
	if !strings.Contains(err.Error(), "security-context patch") {
		t.Fatalf("error %q does not identify the missing security-context patch", err)
	}
	if !strings.Contains(err.Error(), "neon-compute") {
		t.Fatalf("error %q does not identify the missing component role", err)
	}
}

func testHelmReleaseDocument() map[string]any {
	return map[string]any{
		"apiVersion": "helm.toolkit.fluxcd.io/v2",
		"kind":       "HelmRelease",
		"metadata": map[string]any{
			"name":      "generic-release",
			"namespace": "generic-system",
		},
		"spec": map[string]any{
			"postRenderers": []any{map[string]any{
				"kustomize": map[string]any{
					"patches": []any{
						map[string]any{
							"target": map[string]any{
								"version": "v1",
								"kind":    "ConfigMap",
								"name":    "generic-scripts",
							},
							"patch": "- op: replace\n  path: /data/script\n  value: generic\n",
						},
						map[string]any{
							"target": map[string]any{
								"group":   "apps.kubeblocks.io",
								"version": "v1",
								"kind":    "ComponentVersion",
								"name":    "neon-.*",
							},
							"patch": "- op: add\n  path: /spec/releases/0/changes\n  value: \"\"\n- op: remove\n  path: /spec/releases/0/changes\n",
						},
						securityContextTestPatch("neon-pageserver-test"),
						securityContextTestPatch("neon-safekeeper-test"),
						securityContextTestPatch("neon-compute-test"),
					},
				},
			}},
		},
	}
}

func securityContextTestPatch(name string) map[string]any {
	return map[string]any{
		"target": map[string]any{
			"group":   "apps.kubeblocks.io",
			"version": "v1",
			"kind":    "ComponentDefinition",
			"name":    name,
		},
		"patch": "- op: add\n  path: /spec/runtime/securityContext\n  value:\n    fsGroup: 996\n    fsGroupChangePolicy: OnRootMismatch\n",
	}
}

func runKubeBlocksNeonSemanticPolicies(t *testing.T) {
	t.Helper()
	evaluator := newTestPolicyEvaluator(t)
	resources := mustRenderKubeBlocksFixture(t, "component-versions.yaml")
	resources = append(resources, mustRenderKubeBlocksFixture(t, "component-definitions.yaml")...)
	resources = append(resources, mustLoadPolicyResources(t, repoPath("clusters", "home", "resources", "neon-demo.yaml"))...)
	resources = append(resources, mustLoadPolicyResources(t, repoPath("clusters", "home", "configs", "external-secrets", "neon.yaml"))...)
	resources = append(resources, mustLoadPolicyResources(t, repoPath("components", "kubeblocks", "release.yaml"))...)
	resources, componentDefinitionNames := alignKubeBlocksFixtureNames(t, resources)
	baseInput := PolicyInput{
		Resources: resources,
		Context:   policyContext("kubeblocks"),
	}
	assertPolicyPasses(t, evaluator, baseInput)

	t.Run("applies common policies to mixed render resources", func(t *testing.T) {
		mixedResources := appendPolicyResources(resources, []PolicyResource{{
			Source: "render:components/kubeblocks/workload.yaml",
			Document: deploymentDocument("mixed-render-workload", "database", map[string]string{
				"image": "nginx:latest",
			}, nil),
		}})
		assertPolicyFails(t, evaluator, PolicyInput{
			Resources: mixedResources,
			Context:   baseInput.Context,
		}, "image-must-not-use-latest")
	})

	t.Run("rejects a broken Cluster componentDef", func(t *testing.T) {
		mutated := mutateKubeBlocksComponent(resources, "neon-pageserver", func(component map[string]any) {
			component["componentDef"] = "neon-safekeeper-broken"
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-cluster-component-definition-wiring")
	})

	t.Run("rejects a ComponentVersion release changes field", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentVersion", "", componentDefinitionNames["compute"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			releases := document["spec"].(map[string]any)["releases"].([]any)
			release := cloneMap(releases[0].(map[string]any))
			release["changes"] = "unexpected"
			releases[0] = release
			document["spec"].(map[string]any)["releases"] = releases
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-component-version-must-not-retain-changes")
	})

	t.Run("requires all component roles", func(t *testing.T) {
		mutated := removeResourceByKindName(resources, "ComponentVersion", "", componentDefinitionNames["broker"])
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-component-version-roles-must-exist")
	})

	t.Run("requires all ComponentDefinition roles", func(t *testing.T) {
		for _, role := range []string{"compute", "pageserver", "safekeeper"} {
			t.Run(role, func(t *testing.T) {
				mutated := removeResourceByKindName(resources, "ComponentDefinition", "", componentDefinitionNames[role])
				assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-component-definition-roles-must-exist")
			})
		}
	})

	t.Run("requires runtime security context on required definitions", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentDefinition", "", componentDefinitionNames["compute"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			delete(document["spec"].(map[string]any)["runtime"].(map[string]any), "securityContext")
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-component-definition-must-have-security-context")
	})

	t.Run("requires S3 credential Secret references", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentDefinition", "", componentDefinitionNames["pageserver"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			containers := document["spec"].(map[string]any)["runtime"].(map[string]any)["containers"].([]any)
			container := cloneMap(containers[0].(map[string]any))
			env := cloneSlice(container["env"].([]any))
			credential := cloneMap(env[0].(map[string]any))
			credential["value"] = "literal-secret"
			delete(credential, "valueFrom")
			env[0] = credential
			container["env"] = env
			containers[0] = container
			document["spec"].(map[string]any)["runtime"].(map[string]any)["containers"] = containers
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-s3-credentials-must-use-secret-key-ref")
	})

	t.Run("requires S3 credential Secret references in initContainers", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentDefinition", "", componentDefinitionNames["pageserver"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			spec := cloneMap(document["spec"].(map[string]any))
			runtime := cloneMap(spec["runtime"].(map[string]any))
			initContainers := cloneSlice(runtime["initContainers"].([]any))
			initContainer := cloneMap(initContainers[0].(map[string]any))
			env := cloneSlice(initContainer["env"].([]any))
			for index, value := range env {
				entry := cloneMap(value.(map[string]any))
				if entry["name"] != "RCLONE_CONFIG_NEON_ACCESS_KEY_ID" {
					continue
				}
				entry["value"] = "literal-secret"
				delete(entry, "valueFrom")
				env[index] = entry
			}
			initContainer["env"] = env
			initContainers[0] = initContainer
			runtime["initContainers"] = initContainers
			spec["runtime"] = runtime
			document["spec"] = spec
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-s3-credentials-must-use-secret-key-ref")
	})

	t.Run("rejects a plaintext duplicate of a valid S3 credential", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentDefinition", "", componentDefinitionNames["pageserver"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			spec := cloneMap(document["spec"].(map[string]any))
			runtime := cloneMap(spec["runtime"].(map[string]any))
			containers := cloneSlice(runtime["containers"].([]any))
			container := cloneMap(containers[0].(map[string]any))
			env := cloneSlice(container["env"].([]any))
			env = append(env, map[string]any{
				"name":  "AWS_ACCESS_KEY_ID",
				"value": "plaintext-secret",
			})
			container["env"] = env
			containers[0] = container
			runtime["containers"] = containers
			spec["runtime"] = runtime
			document["spec"] = spec
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-s3-credentials-must-use-secret-key-ref")
	})

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
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-addon-controller-must-remain-disabled")
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
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-auto-installed-addons-must-remain-empty")
	})

	t.Run("requires the Neon remote storage script contract", func(t *testing.T) {
		mutated := replaceResource(resources, "ConfigMap", "", "neon-scripts-template", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			data := cloneMap(document["data"].(map[string]any))
			data["pageserver_start.sh"] = strings.ReplaceAll(data["pageserver_start.sh"].(string), "bucket_name='neon-demo'", "bucket_name='other'")
			document["data"] = data
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-neon-remote-storage-must-match-contract")
	})

	t.Run("requires the Neon rclone path-style contract", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentDefinition", "", componentDefinitionNames["pageserver"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			runtime := cloneMap(document["spec"].(map[string]any)["runtime"].(map[string]any))
			initContainers := cloneSlice(runtime["initContainers"].([]any))
			initContainer := cloneMap(initContainers[0].(map[string]any))
			env := cloneSlice(initContainer["env"].([]any))
			for _, value := range env {
				entry := value.(map[string]any)
				if entry["name"] == "RCLONE_CONFIG_NEON_FORCE_PATH_STYLE" {
					entry["value"] = "false"
				}
			}
			initContainer["env"] = env
			initContainers[0] = initContainer
			runtime["initContainers"] = initContainers
			document["spec"].(map[string]any)["runtime"] = runtime
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-neon-remote-storage-must-match-contract")
	})

	t.Run("requires digest-pinned ComponentDefinition images", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentDefinition", "", componentDefinitionNames["pageserver"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			container := cloneMap(document["spec"].(map[string]any)["runtime"].(map[string]any)["containers"].([]any)[0].(map[string]any))
			container["image"] = "example.invalid/neon-pageserver:stable"
			document["spec"].(map[string]any)["runtime"].(map[string]any)["containers"].([]any)[0] = container
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-image-must-be-digest-pinned")
	})

	t.Run("rejects malformed ComponentDefinition image digests", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentDefinition", "", componentDefinitionNames["pageserver"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			container := cloneMap(document["spec"].(map[string]any)["runtime"].(map[string]any)["containers"].([]any)[0].(map[string]any))
			container["image"] = "example.invalid/neon-pageserver:stable@sha256:not-a-digest"
			document["spec"].(map[string]any)["runtime"].(map[string]any)["containers"].([]any)[0] = container
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-image-must-be-digest-pinned")
	})

	t.Run("rejects unpinned latest ComponentVersion images", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentVersion", "", componentDefinitionNames["pageserver"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			releases := cloneSlice(document["spec"].(map[string]any)["releases"].([]any))
			release := cloneMap(releases[0].(map[string]any))
			images := cloneMap(release["images"].(map[string]any))
			images["neon-pageserver"] = "example.invalid/neon-pageserver:latest"
			release["images"] = images
			releases[0] = release
			document["spec"].(map[string]any)["releases"] = releases
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-image-must-not-use-latest")
	})

	t.Run("rejects malformed ComponentVersion image digests", func(t *testing.T) {
		mutated := replaceResource(resources, "ComponentVersion", "", componentDefinitionNames["pageserver"], func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			releases := cloneSlice(document["spec"].(map[string]any)["releases"].([]any))
			release := cloneMap(releases[0].(map[string]any))
			images := cloneMap(release["images"].(map[string]any))
			images["neon-pageserver"] = "example.invalid/neon-pageserver:stable@sha256:not-a-digest"
			release["images"] = images
			releases[0] = release
			document["spec"].(map[string]any)["releases"] = releases
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-image-must-be-digest-pinned")
	})

	t.Run("requires ExternalSecret remoteRef sources", func(t *testing.T) {
		testCases := []struct {
			name   string
			mutate func(map[string]any)
		}{
			{
				name: "missing remoteRef",
				mutate: func(entry map[string]any) {
					delete(entry, "remoteRef")
				},
			},
			{
				name: "wrong remoteRef",
				mutate: func(entry map[string]any) {
					entry["remoteRef"] = map[string]any{"key": "unrelated/credential"}
				},
			},
		}
		for _, tc := range testCases {
			t.Run(tc.name, func(t *testing.T) {
				mutated := mutateKubeBlocksExternalSecret(resources, "AWS_ACCESS_KEY_ID", tc.mutate)
				assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-s3-external-secret-must-use-expected-remote-ref")
			})
		}
	})

	t.Run("requires ExternalSecret credential entries", func(t *testing.T) {
		for _, credentialName := range []string{"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"} {
			t.Run(credentialName, func(t *testing.T) {
				mutated := removeKubeBlocksExternalSecretCredential(resources, credentialName)
				assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-s3-external-secret-must-provide-credentials")
			})
		}
	})

	t.Run("requires ExternalSecret target to match the consumed Secret", func(t *testing.T) {
		mutated := replaceResource(resources, "ExternalSecret", "database", "neon-s3-credentials", func(resource PolicyResource) PolicyResource {
			document := cloneMap(resource.Document)
			spec := cloneMap(document["spec"].(map[string]any))
			target := cloneMap(spec["target"].(map[string]any))
			target["name"] = "unrelated-credentials"
			spec["target"] = target
			document["spec"] = spec
			resource.Document = document
			return resource
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-s3-external-secret-must-target-credential-secret")
	})

	t.Run("rejects destructive WipeOut termination", func(t *testing.T) {
		mutated := mutateKubeBlocksCluster(resources, func(cluster map[string]any) {
			cluster["spec"].(map[string]any)["terminationPolicy"] = "WipeOut"
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-cluster-must-not-use-wipeout")
	})

	t.Run("rejects deprecated clusterDefinitionRef", func(t *testing.T) {
		mutated := mutateKubeBlocksCluster(resources, func(cluster map[string]any) {
			spec := cluster["spec"].(map[string]any)
			spec["clusterDefinitionRef"] = "neon"
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-cluster-must-use-cluster-def")
	})

	t.Run("requires Cluster componentDef wiring to the role ComponentDefinition", func(t *testing.T) {
		mutated := mutateKubeBlocksComponent(resources, "neon-pageserver", func(component map[string]any) {
			component["componentDef"] = "missing-component-definition"
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-cluster-component-definition-wiring")
	})

	t.Run("enforces replicas", func(t *testing.T) {
		mutated := mutateKubeBlocksComponent(resources, "neon-safekeeper", func(component map[string]any) {
			component["replicas"] = 1
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-component-must-match-replicas")
	})

	t.Run("enforces storage", func(t *testing.T) {
		mutated := mutateKubeBlocksComponent(resources, "neon-pageserver", func(component map[string]any) {
			claims := component["volumeClaimTemplates"].([]any)
			claim := cloneMap(claims[0].(map[string]any))
			claimSpec := cloneMap(claim["spec"].(map[string]any))
			claimSpec["storageClassName"] = "other-storage"
			claim["spec"] = claimSpec
			claims[0] = claim
			component["volumeClaimTemplates"] = claims
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-component-must-use-data-volume")
	})

	t.Run("enforces component resources", func(t *testing.T) {
		mutated := mutateKubeBlocksComponent(resources, "neon-compute", func(component map[string]any) {
			component["resources"].(map[string]any)["limits"].(map[string]any)["memory"] = "1Gi"
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-component-must-match-resources")
	})

	t.Run("rejects component scheduling overrides", func(t *testing.T) {
		mutated := mutateKubeBlocksComponent(resources, "neon-compute", func(component map[string]any) {
			component["schedulingPolicy"] = map[string]any{"nodeSelector": map[string]any{"kubernetes.io/arch": "arm64"}}
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-component-must-not-override-scheduling")
	})

	t.Run("rejects a broker volume claim", func(t *testing.T) {
		mutated := mutateKubeBlocksComponent(resources, "neon-broker", func(component map[string]any) {
			component["volumeClaimTemplates"] = []any{map[string]any{"name": "data"}}
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-component-must-use-data-volume")
	})

	t.Run("enforces cluster scheduling", func(t *testing.T) {
		mutated := mutateKubeBlocksCluster(resources, func(cluster map[string]any) {
			delete(cluster["spec"].(map[string]any), "schedulingPolicy")
		})
		assertPolicyFails(t, evaluator, PolicyInput{Resources: mutated, Context: baseInput.Context}, "kubeblocks-cluster-must-schedule-on-amd64")
	})
}

func helmReleasePatches(t *testing.T, document map[string]any) []any {
	t.Helper()
	spec := document["spec"].(map[string]any)
	postRenderers := spec["postRenderers"].([]any)
	postRenderer := postRenderers[0].(map[string]any)
	kustomize := postRenderer["kustomize"].(map[string]any)
	return kustomize["patches"].([]any)
}

func setHelmReleasePatches(document map[string]any, patches []any) {
	spec := document["spec"].(map[string]any)
	postRenderers := spec["postRenderers"].([]any)
	postRenderer := postRenderers[0].(map[string]any)
	kustomize := postRenderer["kustomize"].(map[string]any)
	kustomize["patches"] = patches
}

func writeYAMLDocument(t *testing.T, path string, document map[string]any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	writeYAMLDocuments(t, path, []map[string]any{document})
}

func writeYAMLDocuments(t *testing.T, path string, documents []map[string]any) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	encoder := yaml.NewEncoder(file)
	for _, document := range documents {
		if err := encoder.Encode(document); err != nil {
			_ = file.Close()
			t.Fatal(err)
		}
	}
	if err := encoder.Close(); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}

func readYAMLDocument(t *testing.T, path string) map[string]any {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	documents, err := decodeYAMLDocuments(file)
	if err != nil {
		t.Fatal(err)
	}
	if len(documents) != 1 {
		t.Fatalf("decoded %d YAML documents, want one", len(documents))
	}
	return documents[0]
}

func mustRenderKubeBlocksFixture(t *testing.T, fixture string) []PolicyResource {
	t.Helper()
	tempDir := t.TempDir()
	sourcePath := repoPath("tests", "testdata", "kubeblocks", fixture)
	resourcePath := filepath.Join(tempDir, filepath.Base(sourcePath))
	data, err := os.ReadFile(sourcePath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(resourcePath, data, 0o644); err != nil {
		t.Fatal(err)
	}

	destinationPath := filepath.Join(tempDir, "kustomization.yaml")
	err = writeKustomizationForHelmRelease(
		repoPath("components", "kubeblocks", "neon-release.yaml"),
		resourcePath,
		destinationPath,
	)
	if err != nil {
		t.Fatal(err)
	}
	return mustRenderPolicyResourcesFromRoot(t, tempDir, ".")
}

func alignKubeBlocksFixtureNames(t *testing.T, resources []PolicyResource) ([]PolicyResource, map[string]string) {
	t.Helper()

	cluster := matchingResources(resources, "Cluster", "database", "neon-demo")[0].Document
	components, ok := cluster["spec"].(map[string]any)["componentSpecs"].([]any)
	if !ok {
		t.Fatal("KubeBlocks Cluster componentSpecs are missing")
	}

	componentDefinitionNames := make(map[string]string, len(components))
	for _, value := range components {
		component := value.(map[string]any)
		role := strings.TrimPrefix(component["name"].(string), "neon-")
		componentDefinitionNames[role] = component["componentDef"].(string)
	}
	for _, role := range []string{"broker", "compute", "pageserver", "safekeeper"} {
		if componentDefinitionNames[role] == "" {
			t.Fatalf("KubeBlocks Cluster componentDef for %s is missing", role)
		}
	}

	aligned := append([]PolicyResource(nil), resources...)
	for index, resource := range aligned {
		var role string
		switch resource.Document["kind"] {
		case "ComponentDefinition":
			spec, _ := resource.Document["spec"].(map[string]any)
			role = strings.TrimPrefix(spec["serviceKind"].(string), "neon-")
		case "ComponentVersion":
			name := resourceName(resource.Document)
			if !strings.HasSuffix(name, "-test") {
				continue
			}
			role = strings.TrimSuffix(strings.TrimPrefix(name, "neon-"), "-test")
		default:
			continue
		}

		componentDefinitionName := componentDefinitionNames[role]
		if componentDefinitionName == "" {
			continue
		}
		document := cloneMap(resource.Document)
		metadata := cloneMap(document["metadata"].(map[string]any))
		metadata["name"] = componentDefinitionName
		document["metadata"] = metadata
		aligned[index].Document = document
	}

	return aligned, componentDefinitionNames
}

func mustRenderPolicyResourcesFromRoot(t *testing.T, root, relativePath string) []PolicyResource {
	t.Helper()
	resources, err := renderKustomization(context.Background(), root, relativePath)
	if err != nil {
		t.Fatal(err)
	}
	return resources
}

func mutateKubeBlocksCluster(resources []PolicyResource, mutate func(map[string]any)) []PolicyResource {
	return replaceFirstResource(resources, "Cluster", mutate)
}

func mutateKubeBlocksComponent(resources []PolicyResource, name string, mutate func(map[string]any)) []PolicyResource {
	return replaceNestedClusterComponent(resources, name, mutate)
}

func mutateKubeBlocksExternalSecret(resources []PolicyResource, credentialName string, mutate func(map[string]any)) []PolicyResource {
	return replaceResource(resources, "ExternalSecret", "database", "neon-s3-credentials", func(resource PolicyResource) PolicyResource {
		document := cloneMap(resource.Document)
		spec := cloneMap(document["spec"].(map[string]any))
		data := cloneSlice(spec["data"].([]any))
		for index, value := range data {
			entry := cloneMap(value.(map[string]any))
			if entry["secretKey"] != credentialName {
				continue
			}
			mutate(entry)
			data[index] = entry
		}
		spec["data"] = data
		document["spec"] = spec
		resource.Document = document
		return resource
	})
}

func removeKubeBlocksExternalSecretCredential(resources []PolicyResource, credentialName string) []PolicyResource {
	return replaceResource(resources, "ExternalSecret", "database", "neon-s3-credentials", func(resource PolicyResource) PolicyResource {
		document := cloneMap(resource.Document)
		spec := cloneMap(document["spec"].(map[string]any))
		data := cloneSlice(spec["data"].([]any))
		filtered := make([]any, 0, len(data))
		for _, value := range data {
			entry := value.(map[string]any)
			if entry["secretKey"] == credentialName {
				continue
			}
			filtered = append(filtered, value)
		}
		spec["data"] = filtered
		document["spec"] = spec
		resource.Document = document
		return resource
	})
}

func replaceFirstResource(resources []PolicyResource, kind string, mutate func(map[string]any)) []PolicyResource {
	result := append([]PolicyResource(nil), resources...)
	for index, resource := range result {
		if resource.Document["kind"] != kind {
			continue
		}
		resource.Document = cloneMap(resource.Document)
		mutate(resource.Document)
		result[index] = resource
		return result
	}
	panic("resource not found")
}

func replaceNestedClusterComponent(resources []PolicyResource, name string, mutate func(map[string]any)) []PolicyResource {
	return replaceFirstResource(resources, "Cluster", func(cluster map[string]any) {
		spec := cluster["spec"].(map[string]any)
		components := cloneSlice(spec["componentSpecs"].([]any))
		for index, value := range components {
			component := value.(map[string]any)
			if component["name"] != name {
				continue
			}
			component = cloneMap(component)
			mutate(component)
			components[index] = component
			spec["componentSpecs"] = components
			return
		}
		panic("component not found")
	})
}
