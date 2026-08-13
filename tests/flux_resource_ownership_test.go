package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResourceIdentityNamespacedAndClusterScoped(t *testing.T) {
	namespaced := map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]any{
			"name":      "web",
			"namespace": "apps",
		},
	}
	got, ok := resourceIdentity(namespaced, "home")
	if !ok {
		t.Fatal("resourceIdentity returned no identity")
	}
	want := ResourceIdentity{Cluster: "home", Group: "apps", Kind: "Deployment", Namespace: "apps", Name: "web"}
	if got != want {
		t.Fatalf("identity = %#v, want %#v", got, want)
	}

	clusterScoped := map[string]any{
		"apiVersion": "rbac.authorization.k8s.io/v1",
		"kind":       "ClusterRole",
		"metadata":   map[string]any{"name": "read-only"},
	}
	got, ok = resourceIdentity(clusterScoped, "home")
	if !ok {
		t.Fatal("resourceIdentity returned no cluster-scoped identity")
	}
	want = ResourceIdentity{Cluster: "home", Group: "rbac.authorization.k8s.io", Kind: "ClusterRole", Name: "read-only"}
	if got != want {
		t.Fatalf("cluster identity = %#v, want %#v", got, want)
	}
}

func TestInventoryIdentityIgnoresVersion(t *testing.T) {
	entry := map[string]any{
		"id": "apps_web_apps_Deployment",
		"v":  "v1",
	}
	got, ok := inventoryIdentity(entry, "home")
	if !ok {
		t.Fatal("inventoryIdentity returned no identity")
	}
	want := ResourceIdentity{Cluster: "home", Group: "apps", Kind: "Deployment", Namespace: "apps", Name: "web"}
	if got != want {
		t.Fatalf("identity = %#v, want %#v", got, want)
	}
}

func TestFindDuplicateOwnersSeparatesClusters(t *testing.T) {
	identityHome := ResourceIdentity{Cluster: "home", Group: "", Kind: "Namespace", Name: "shared"}
	identityLocal := identityHome
	identityLocal.Cluster = "local"
	resources := []ResourceOwner{
		{Identity: identityHome, Owner: Owner{Kind: "Kustomization", Namespace: "flux-system", Name: "one"}},
		{Identity: identityHome, Owner: Owner{Kind: "Kustomization", Namespace: "flux-system", Name: "two"}},
		{Identity: identityLocal, Owner: Owner{Kind: "Kustomization", Namespace: "flux-system", Name: "one"}},
	}
	duplicates := findDuplicateOwners(resources)
	if len(duplicates) != 1 {
		t.Fatalf("duplicate identities = %d, want 1", len(duplicates))
	}
	owners := duplicates[identityHome]
	if len(owners) != 2 {
		t.Fatalf("owners = %d, want 2", len(owners))
	}
}

func TestDiscoverKustomizationsIgnoresNativeKustomizationFile(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, root, "clusters/home/flux-system/gotk-sync.yaml", `apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: home
  namespace: flux-system
spec:
  path: ./clusters/home
`)
	writeTestFile(t, root, "clusters/home/kustomization.yaml", `apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
`)

	got, err := discoverKustomizations(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("discovered Kustomizations = %d, want 1", len(got))
	}
	if got[0].Name != "home" || got[0].Namespace != "flux-system" {
		t.Fatalf("discovered = %#v", got[0])
	}
}

func TestClusterScopeLocalAndRemote(t *testing.T) {
	local := discoveredKustomization{
		ManifestPath: "clusters/home/flux-system/gotk-sync.yaml",
		Document:     map[string]any{"metadata": map[string]any{"namespace": "flux-system"}},
	}
	if got := clusterScope(local.ManifestPath, local.Document); got != "home" {
		t.Fatalf("local scope = %q, want home", got)
	}

	remote := discoveredKustomization{
		ManifestPath: "clusters/home/resources/vcluster-app-sync.yaml",
		Document: map[string]any{
			"metadata": map[string]any{"namespace": "app"},
			"spec": map[string]any{
				"kubeConfig": map[string]any{
					"secretRef": map[string]any{"name": "vc-vcluster"},
				},
			},
		},
	}
	if got := clusterScope(remote.ManifestPath, remote.Document); got != "home/remote/app/vc-vcluster" {
		t.Fatalf("remote scope = %q, want home/remote/app/vc-vcluster", got)
	}
}

func TestInventoryOwnersDetectKustomizationAndHelmReleaseCollision(t *testing.T) {
	objects := []map[string]any{
		{
			"apiVersion": "kustomize.toolkit.fluxcd.io/v1",
			"kind":       "Kustomization",
			"metadata":   map[string]any{"name": "platform", "namespace": "flux-system"},
			"status": map[string]any{
				"inventory": map[string]any{"entries": []any{
					map[string]any{"id": "apps_web_apps_Deployment", "v": "v1"},
				}},
			},
		},
		{
			"apiVersion": "helm.toolkit.fluxcd.io/v2",
			"kind":       "HelmRelease",
			"metadata":   map[string]any{"name": "web", "namespace": "apps"},
			"status": map[string]any{
				"inventory": map[string]any{"entries": []any{
					map[string]any{"id": "apps_web_apps_Deployment", "v": "v1"},
				}},
			},
		},
	}
	resources, err := inventoryOwners(objects, "home")
	if err != nil {
		t.Fatal(err)
	}
	duplicates := findDuplicateOwners(resources)
	identity := ResourceIdentity{Cluster: "home", Group: "apps", Kind: "Deployment", Namespace: "apps", Name: "web"}
	if len(duplicates[identity]) != 2 {
		t.Fatalf("collision owners = %#v, want 2 owners", duplicates[identity])
	}
}

func TestReportDuplicatesIsDeterministic(t *testing.T) {
	identity := ResourceIdentity{Cluster: "home", Group: "apps", Kind: "Deployment", Namespace: "apps", Name: "web"}
	owners := []ResourceOwner{
		{Identity: identity, Owner: Owner{Kind: "HelmRelease", Namespace: "apps", Name: "web"}},
		{Identity: identity, Owner: Owner{Kind: "Kustomization", Namespace: "flux-system", Name: "platform"}},
	}
	first := formatDuplicates(map[ResourceIdentity][]Owner{identity: {owners[0].Owner, owners[1].Owner}})
	second := formatDuplicates(map[ResourceIdentity][]Owner{identity: {owners[1].Owner, owners[0].Owner}})
	if first != second || !strings.Contains(first, "Duplicate resource ownership detected") {
		t.Fatalf("non-deterministic report:\n%s\n---\n%s", first, second)
	}
}

func TestRepositoryContractDocumentation(t *testing.T) {
	workflow, err := os.ReadFile(filepath.Join("..", ".github", "workflows", "ci.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	documentation, err := os.ReadFile(filepath.Join("..", "docs", "flux-resource-ownership.md"))
	if err != nil {
		t.Fatal(err)
	}
	workflowText := string(workflow)
	if strings.Count(workflowText, "go test ./...") != 1 {
		t.Fatalf("CI must have exactly one go test ./... entry point, found %d", strings.Count(workflowText, "go test ./..."))
	}
	for _, required := range []string{
		"Install Kustomize",
		"go install sigs.k8s.io/kustomize/kustomize/v5@",
		"fluxcd/flux2/action@",
		"mkdir -p .flux-tmp",
		"TMPDIR: ${{ github.workspace }}/.flux-tmp",
		"go run ./tests repository --repo-root .",
		"flux-schema/actions/setup@",
		"flux-schema/actions/validate@",
	} {
		if !strings.Contains(workflowText, required) {
			t.Fatalf("CI does not contain %q", required)
		}
	}
	manifestPolicyDocumentation, err := os.ReadFile(filepath.Join("..", "docs", "manifest-policy-testing.md"))
	if err != nil {
		t.Fatal(err)
	}
	documentationText := string(documentation)
	for _, required := range []string{"kubectl get kustomizations", "kubectl get helmreleases", "status.inventory", "Helm hooks"} {
		if !strings.Contains(documentationText, required) {
			t.Fatalf("documentation does not contain %q", required)
		}
	}
	manifestPolicyDocumentationText := string(manifestPolicyDocumentation)
	for _, required := range []string{
		"go test ./...",
		"go run ./tests repository --repo-root .",
		"Kustomize",
		"no Kubernetes cluster",
		"Flux Schema",
		"network access",
	} {
		if !strings.Contains(manifestPolicyDocumentationText, required) {
			t.Fatalf("manifest policy documentation does not contain %q", required)
		}
	}
}

func writeTestFile(t *testing.T, root, relativePath, content string) {
	t.Helper()
	path := filepath.Join(root, relativePath)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
