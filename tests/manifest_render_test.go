package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRenderKustomizationReturnsStructuredResources(t *testing.T) {
	t.Setenv("TEST_KUSTOMIZE_STDOUT", strings.TrimSpace(`
apiVersion: v1
kind: Namespace
metadata:
  name: sandbox
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: sandbox
`))
	t.Setenv("TEST_KUSTOMIZE_STDERR", "")
	t.Setenv("TEST_KUSTOMIZE_EXIT_CODE", "0")

	previous := execCommandContext
	execCommandContext = fakeExecCommandContext(t)
	t.Cleanup(func() {
		execCommandContext = previous
	})

	resources, err := renderKustomization(context.Background(), "/repo", "clusters/sandbox")
	if err != nil {
		t.Fatal(err)
	}

	want := []PolicyResource{
		{
			Source: "render:clusters/sandbox",
			Document: map[string]any{
				"apiVersion": "v1",
				"kind":       "Namespace",
				"metadata": map[string]any{
					"name": "sandbox",
				},
			},
		},
		{
			Source: "render:clusters/sandbox",
			Document: map[string]any{
				"apiVersion": "apps/v1",
				"kind":       "Deployment",
				"metadata": map[string]any{
					"name":      "app",
					"namespace": "sandbox",
				},
			},
		},
	}
	if !reflect.DeepEqual(resources, want) {
		t.Fatalf("resources = %#v, want %#v", resources, want)
	}
}

func TestRenderKustomizationPreservesCommandFailureDetails(t *testing.T) {
	t.Setenv("TEST_KUSTOMIZE_STDOUT", "")
	t.Setenv("TEST_KUSTOMIZE_STDERR", "  synthetic stderr  \n")
	t.Setenv("TEST_KUSTOMIZE_EXIT_CODE", "7")

	previous := execCommandContext
	execCommandContext = fakeExecCommandContext(t)
	t.Cleanup(func() {
		execCommandContext = previous
	})

	_, err := renderKustomization(context.Background(), "/repo", "clusters/sandbox")
	if err == nil {
		t.Fatal("renderKustomization succeeded, want error")
	}

	message := err.Error()
	for _, fragment := range []string{
		filepath.Join("/repo", "clusters/sandbox"),
		"exit status 7",
		"synthetic stderr",
	} {
		if !strings.Contains(message, fragment) {
			t.Fatalf("error %q does not contain %q", message, fragment)
		}
	}
}

func TestLoadPolicyResourcesFromFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "resources.yaml")
	if err := os.WriteFile(path, []byte(strings.TrimSpace(`
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
---
apiVersion: v1
kind: Secret
metadata:
  name: creds
`)), 0o644); err != nil {
		t.Fatal(err)
	}

	resources, err := loadPolicyResources(path)
	if err != nil {
		t.Fatal(err)
	}

	want := []PolicyResource{
		{
			Source: path,
			Document: map[string]any{
				"apiVersion": "v1",
				"kind":       "ConfigMap",
				"metadata": map[string]any{
					"name": "config",
				},
			},
		},
		{
			Source: path,
			Document: map[string]any{
				"apiVersion": "v1",
				"kind":       "Secret",
				"metadata": map[string]any{
					"name": "creds",
				},
			},
		},
	}
	if !reflect.DeepEqual(resources, want) {
		t.Fatalf("resources = %#v, want %#v", resources, want)
	}
}

func TestLoadPolicyResourcesRejectsNonYAMLFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "resources.json")
	if err := os.WriteFile(path, []byte(`{"apiVersion":"v1","kind":"ConfigMap"}`), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := loadPolicyResources(path)
	if err == nil {
		t.Fatal("loadPolicyResources succeeded, want error")
	}
	if !strings.Contains(err.Error(), "must be a YAML file") {
		t.Fatalf("error %q does not contain %q", err.Error(), "must be a YAML file")
	}
}

func TestLoadPolicyResourcesFromDirectory(t *testing.T) {
	dir := t.TempDir()
	first := filepath.Join(dir, "a.yaml")
	second := filepath.Join(dir, "b.yml")
	if err := os.WriteFile(first, []byte(strings.TrimSpace(`
apiVersion: v1
kind: Service
metadata:
  name: frontend
`)), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, []byte(strings.TrimSpace(`
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: database
`)), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ignored.txt"), []byte("ignore"), 0o644); err != nil {
		t.Fatal(err)
	}

	resources, err := loadPolicyResources(dir)
	if err != nil {
		t.Fatal(err)
	}

	want := []PolicyResource{
		{
			Source: first,
			Document: map[string]any{
				"apiVersion": "v1",
				"kind":       "Service",
				"metadata": map[string]any{
					"name": "frontend",
				},
			},
		},
		{
			Source: second,
			Document: map[string]any{
				"apiVersion": "apps/v1",
				"kind":       "StatefulSet",
				"metadata": map[string]any{
					"name": "database",
				},
			},
		},
	}
	if !reflect.DeepEqual(resources, want) {
		t.Fatalf("resources = %#v, want %#v", resources, want)
	}
}

func fakeExecCommandContext(t *testing.T) func(context.Context, string, ...string) *exec.Cmd {
	t.Helper()
	return func(ctx context.Context, name string, args ...string) *exec.Cmd {
		t.Helper()
		commandArgs := []string{"-test.run=TestManifestRenderExecHelperProcess", "--", name}
		commandArgs = append(commandArgs, args...)
		cmd := exec.CommandContext(ctx, os.Args[0], commandArgs...)
		cmd.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
		return cmd
	}
}

func TestManifestRenderExecHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}

	args := os.Args
	separator := -1
	for index, arg := range args {
		if arg == "--" {
			separator = index
			break
		}
	}
	if separator == -1 {
		fmt.Fprintln(os.Stderr, "missing helper separator")
		os.Exit(2)
	}

	got := strings.Join(args[separator+1:], " ")
	want := fmt.Sprintf("kustomize build %s", filepath.Join("/repo", "clusters/sandbox"))
	if got != want {
		fmt.Fprintf(os.Stderr, "got %q want %q", got, want)
		os.Exit(3)
	}

	fmt.Fprint(os.Stdout, os.Getenv("TEST_KUSTOMIZE_STDOUT"))
	fmt.Fprint(os.Stderr, os.Getenv("TEST_KUSTOMIZE_STDERR"))

	exitCode := 0
	if _, err := fmt.Sscanf(os.Getenv("TEST_KUSTOMIZE_EXIT_CODE"), "%d", &exitCode); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(4)
	}
	os.Exit(exitCode)
}
