package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

var execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, name, args...)
}

func renderKustomization(ctx context.Context, repoRoot, relativePath string) ([]PolicyResource, error) {
	targetPath := filepath.Join(repoRoot, filepath.FromSlash(relativePath))
	command := execCommandContext(ctx, "kustomize", "build", targetPath)
	output, err := command.Output()
	if err != nil {
		stderr := ""
		if exitErr := new(exec.ExitError); errorAs(err, &exitErr) {
			stderr = strings.TrimSpace(string(exitErr.Stderr))
		}
		if stderr != "" {
			return nil, fmt.Errorf("render %s: %w: %s", targetPath, err, stderr)
		}
		return nil, fmt.Errorf("render %s: %w", targetPath, err)
	}

	documents, err := decodeYAMLDocuments(strings.NewReader(string(output)))
	if err != nil {
		return nil, fmt.Errorf("decode rendered manifests %s: %w", targetPath, err)
	}
	return policyResourcesFromDocuments("render:"+filepath.ToSlash(relativePath), documents), nil
}

func loadPolicyResources(path string) ([]PolicyResource, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("stat %s: %w", path, err)
	}

	if !info.IsDir() {
		ext := strings.ToLower(filepath.Ext(path))
		if ext != ".yaml" && ext != ".yml" {
			return nil, fmt.Errorf("load %s: must be a YAML file", path)
		}
		return loadPolicyResourceFile(path)
	}

	entries, err := os.ReadDir(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}

	var names []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if ext != ".yaml" && ext != ".yml" {
			continue
		}
		names = append(names, entry.Name())
	}
	sort.Strings(names)

	var resources []PolicyResource
	for _, name := range names {
		filePath := filepath.Join(path, name)
		loaded, err := loadPolicyResourceFile(filePath)
		if err != nil {
			return nil, err
		}
		resources = append(resources, loaded...)
	}
	return resources, nil
}

func policyResourcesFromDocuments(source string, documents []map[string]any) []PolicyResource {
	resources := make([]PolicyResource, 0, len(documents))
	for _, document := range documents {
		resources = append(resources, PolicyResource{
			Source:   source,
			Document: document,
		})
	}
	return resources
}

func loadPolicyResourceFile(path string) ([]PolicyResource, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	documents, decodeErr := decodeYAMLDocuments(file)
	closeErr := file.Close()
	if decodeErr != nil {
		return nil, fmt.Errorf("decode %s: %w", path, decodeErr)
	}
	if closeErr != nil {
		return nil, fmt.Errorf("close %s: %w", path, closeErr)
	}
	return policyResourcesFromDocuments(path, documents), nil
}

func errorAs(err error, target any) bool { return errors.As(err, target) }
