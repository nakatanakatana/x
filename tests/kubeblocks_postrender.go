package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

var requiredKubeBlocksSecurityContextRoles = []string{
	"neon-pageserver",
	"neon-safekeeper",
	"neon-compute",
}

func writeKustomizationForHelmRelease(helmReleasePath, resourcePath, destinationPath string) error {
	file, err := os.Open(helmReleasePath)
	if err != nil {
		return fmt.Errorf("open HelmRelease %s: %w", helmReleasePath, err)
	}
	documents, decodeErr := decodeYAMLDocuments(file)
	closeErr := file.Close()
	if decodeErr != nil {
		return fmt.Errorf("decode HelmRelease %s: %w", helmReleasePath, decodeErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close HelmRelease %s: %w", helmReleasePath, closeErr)
	}
	if len(documents) == 0 {
		return fmt.Errorf("HelmRelease %s contains no YAML document", helmReleasePath)
	}
	if len(documents) > 1 {
		return fmt.Errorf("HelmRelease %s contains multiple YAML documents (%d); expected exactly one", helmReleasePath, len(documents))
	}

	patches, err := helmReleaseKustomizePatches(documents[0])
	if err != nil {
		return fmt.Errorf("read post-render patches from %s: %w", helmReleasePath, err)
	}
	if err := validateKubeBlocksPostRenderPatches(patches); err != nil {
		return fmt.Errorf("validate post-render patches in %s: %w", helmReleasePath, err)
	}

	if err := os.MkdirAll(filepath.Dir(destinationPath), 0o755); err != nil {
		return fmt.Errorf("create Kustomization directory %s: %w", filepath.Dir(destinationPath), err)
	}
	destination, err := os.Create(destinationPath)
	if err != nil {
		return fmt.Errorf("create Kustomization %s: %w", destinationPath, err)
	}
	encoder := yaml.NewEncoder(destination)
	encoder.SetIndent(2)
	document := map[string]any{
		"apiVersion": "kustomize.config.k8s.io/v1beta1",
		"kind":       "Kustomization",
		"resources":  []any{filepath.Base(resourcePath)},
		"patches":    patches,
	}
	encodeErr := encoder.Encode(document)
	closeEncoderErr := encoder.Close()
	closeErr = destination.Close()
	if encodeErr != nil {
		return fmt.Errorf("write Kustomization %s: %w", destinationPath, encodeErr)
	}
	if closeEncoderErr != nil {
		return fmt.Errorf("close Kustomization encoder %s: %w", destinationPath, closeEncoderErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close Kustomization %s: %w", destinationPath, closeErr)
	}
	return nil
}

func helmReleaseKustomizePatches(document map[string]any) ([]any, error) {
	spec, ok := document["spec"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("spec must be an object")
	}
	postRenderers, ok := spec["postRenderers"].([]any)
	if !ok || len(postRenderers) == 0 {
		return nil, fmt.Errorf("spec.postRenderers must contain a Kustomize renderer")
	}
	if len(postRenderers) > 1 {
		return nil, fmt.Errorf("spec.postRenderers contains multiple post-renderers (%d); expected exactly one", len(postRenderers))
	}
	postRenderer, ok := postRenderers[0].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("spec.postRenderers[0] must be an object")
	}
	kustomize, ok := postRenderer["kustomize"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("spec.postRenderers[0].kustomize must be an object")
	}
	patches, ok := kustomize["patches"].([]any)
	if !ok {
		return nil, fmt.Errorf("spec.postRenderers[0].kustomize.patches must be an array")
	}
	return patches, nil
}

func validateKubeBlocksPostRenderPatches(patches []any) error {
	componentVersionCount := 0
	securityContextPatches := make(map[string]int, len(requiredKubeBlocksSecurityContextRoles))
	for _, role := range requiredKubeBlocksSecurityContextRoles {
		securityContextPatches[role] = 0
	}

	for index, value := range patches {
		patch, ok := value.(map[string]any)
		if !ok {
			return fmt.Errorf("patch %d must be an object", index)
		}
		target, ok := patch["target"].(map[string]any)
		if !ok {
			return fmt.Errorf("patch %d target must be an object", index)
		}
		group, _ := target["group"].(string)
		version, _ := target["version"].(string)
		kind, _ := target["kind"].(string)
		name, _ := target["name"].(string)
		if group == "apps.kubeblocks.io" && version == "v1" && kind == "ComponentVersion" {
			componentVersionCount++
			if !isNeonComponentTarget(name) {
				return fmt.Errorf("ComponentVersion target name must use the generic neon- prefix")
			}
			if err := validateComponentVersionPatch(patch, index); err != nil {
				return err
			}
		}
		for _, role := range requiredKubeBlocksSecurityContextRoles {
			if group != "apps.kubeblocks.io" || version != "v1" || kind != "ComponentDefinition" || !isKubeBlocksRoleTarget(name, role) {
				continue
			}
			securityContextPatches[role]++
			if err := validateSecurityContextPatch(patch, role, index); err != nil {
				return err
			}
		}
	}

	if componentVersionCount != 1 {
		return fmt.Errorf("expected exactly one ComponentVersion patch target, found %d", componentVersionCount)
	}
	for _, role := range requiredKubeBlocksSecurityContextRoles {
		if securityContextPatches[role] != 1 {
			return fmt.Errorf("expected exactly one %s security-context patch, found %d", role, securityContextPatches[role])
		}
	}
	return nil
}

func isNeonComponentTarget(name string) bool {
	return strings.HasPrefix(name, "neon-")
}

func isKubeBlocksRoleTarget(name, role string) bool {
	return name == role || strings.HasPrefix(name, role+"-")
}

func validateComponentVersionPatch(patch map[string]any, index int) error {
	operations, err := patchOperations(patch, index)
	if err != nil {
		return err
	}
	if len(operations) != 2 {
		return fmt.Errorf("ComponentVersion patch %d must add and remove spec.releases[0].changes", index)
	}
	add := operations[0]
	remove := operations[1]
	if add["op"] != "add" || add["path"] != "/spec/releases/0/changes" || add["value"] != "" {
		return fmt.Errorf("ComponentVersion patch %d must first add an empty changes field", index)
	}
	if remove["op"] != "remove" || remove["path"] != "/spec/releases/0/changes" {
		return fmt.Errorf("ComponentVersion patch %d must then remove the changes field", index)
	}
	return nil
}

func validateSecurityContextPatch(patch map[string]any, role string, index int) error {
	operations, err := patchOperations(patch, index)
	if err != nil {
		return err
	}
	for _, operation := range operations {
		if operation["op"] != "add" || operation["path"] != "/spec/runtime/securityContext" {
			continue
		}
		value, ok := operation["value"].(map[string]any)
		if ok && value["fsGroup"] == 996 && value["fsGroupChangePolicy"] == "OnRootMismatch" {
			return nil
		}
	}
	return fmt.Errorf("%s security-context patch %d must set fsGroup=996 and fsGroupChangePolicy=OnRootMismatch", role, index)
}

func patchOperations(patch map[string]any, index int) ([]map[string]any, error) {
	patchText, ok := patch["patch"].(string)
	if !ok || strings.TrimSpace(patchText) == "" {
		return nil, fmt.Errorf("patch %d must contain an inline YAML patch", index)
	}
	var operations []map[string]any
	if err := yaml.Unmarshal([]byte(patchText), &operations); err != nil {
		return nil, fmt.Errorf("decode inline patch %d: %w", index, err)
	}
	return operations, nil
}
