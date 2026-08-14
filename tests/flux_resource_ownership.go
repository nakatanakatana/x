package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// ResourceIdentity is the identity Flux uses to distinguish a Kubernetes
// resource within one cluster scope.
type ResourceIdentity struct {
	Cluster   string
	Group     string
	Kind      string
	Namespace string
	Name      string
}

type Owner struct {
	Kind      string
	Namespace string
	Name      string
	Source    string
}

type ResourceOwner struct {
	Identity ResourceIdentity
	Owner    Owner
}

type discoveredKustomization struct {
	ManifestPath string
	Name         string
	Namespace    string
	Document     map[string]any
}

var clusterScopedKinds = map[string]bool{
	"APIService":                     true,
	"ClusterRole":                    true,
	"ClusterRoleBinding":             true,
	"CustomResourceDefinition":       true,
	"MutatingWebhookConfiguration":   true,
	"Namespace":                      true,
	"Node":                           true,
	"PersistentVolume":               true,
	"PodSecurityPolicy":              true,
	"PriorityClass":                  true,
	"StorageClass":                   true,
	"ValidatingWebhookConfiguration": true,
}

func resourceIdentity(document map[string]any, cluster string) (ResourceIdentity, bool) {
	apiVersion := stringField(document, "apiVersion")
	kind := stringField(document, "kind")
	metadata := mapField(document, "metadata")
	name := stringField(metadata, "name")
	if apiVersion == "" || kind == "" || name == "" {
		return ResourceIdentity{}, false
	}

	group := ""
	if parts := strings.SplitN(apiVersion, "/", 2); len(parts) == 2 {
		group = parts[0]
	}
	namespace := ""
	if !clusterScopedKinds[kind] {
		namespace = stringField(metadata, "namespace")
	}
	return ResourceIdentity{Cluster: cluster, Group: group, Kind: kind, Namespace: namespace, Name: name}, true
}

func inventoryIdentity(entry map[string]any, cluster string) (ResourceIdentity, bool) {
	parts := strings.SplitN(stringField(entry, "id"), "_", 4)
	if len(parts) != 4 || parts[1] == "" || parts[3] == "" {
		return ResourceIdentity{}, false
	}
	return ResourceIdentity{
		Cluster:   cluster,
		Namespace: parts[0],
		Name:      parts[1],
		Group:     parts[2],
		Kind:      parts[3],
	}, true
}

func findDuplicateOwners(resources []ResourceOwner) map[ResourceIdentity][]Owner {
	ownersByIdentity := make(map[ResourceIdentity]map[Owner]struct{})
	for _, resource := range resources {
		if _, ok := ownersByIdentity[resource.Identity]; !ok {
			ownersByIdentity[resource.Identity] = make(map[Owner]struct{})
		}
		ownersByIdentity[resource.Identity][resource.Owner] = struct{}{}
	}

	duplicates := make(map[ResourceIdentity][]Owner)
	for identity, owners := range ownersByIdentity {
		if len(owners) < 2 {
			continue
		}
		for owner := range owners {
			duplicates[identity] = append(duplicates[identity], owner)
		}
		sort.Slice(duplicates[identity], func(i, j int) bool {
			return ownerSortKey(duplicates[identity][i]) < ownerSortKey(duplicates[identity][j])
		})
	}
	return duplicates
}

func discoverKustomizations(repoRoot string) ([]discoveredKustomization, error) {
	var result []discoveredKustomization
	err := filepath.WalkDir(repoRoot, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if entry.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if ext != ".yaml" && ext != ".yml" {
			return nil
		}

		file, err := os.Open(path)
		if err != nil {
			return err
		}
		documents, decodeErr := decodeYAMLDocuments(file)
		closeErr := file.Close()
		if decodeErr != nil {
			return fmt.Errorf("decode %s: %w", path, decodeErr)
		}
		if closeErr != nil {
			return closeErr
		}
		for _, document := range documents {
			if !isFluxKustomization(document) {
				continue
			}
			metadata := mapField(document, "metadata")
			name := stringField(metadata, "name")
			if name == "" {
				return fmt.Errorf("Flux Kustomization in %s has no metadata.name", path)
			}
			namespace := stringField(metadata, "namespace")
			if namespace == "" {
				namespace = "default"
			}
			relativePath, err := filepath.Rel(repoRoot, path)
			if err != nil {
				return err
			}
			result = append(result, discoveredKustomization{
				ManifestPath: filepath.ToSlash(relativePath),
				Name:         name,
				Namespace:    namespace,
				Document:     document,
			})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(result, func(i, j int) bool {
		return result[i].ManifestPath < result[j].ManifestPath
	})
	return result, nil
}

func clusterScope(manifestPath string, kustomization map[string]any) string {
	parts := strings.Split(filepath.ToSlash(filepath.Clean(manifestPath)), "/")
	cluster := "unknown"
	for i, part := range parts[:max(0, len(parts)-1)] {
		if part == "clusters" && i+1 < len(parts)-1 {
			cluster = parts[i+1]
			break
		}
	}

	spec := mapField(kustomization, "spec")
	ref := mapField(mapField(spec, "kubeConfig"), "secretRef")
	name := stringField(ref, "name")
	if name != "" {
		namespace := stringField(ref, "namespace")
		if namespace == "" {
			namespace = stringField(mapField(kustomization, "metadata"), "namespace")
		}
		return fmt.Sprintf("%s/remote/%s/%s", cluster, namespace, name)
	}
	return cluster
}

func renderOwnershipKustomization(repoRoot, fluxBinary string, kustomization discoveredKustomization) ([]ResourceOwner, error) {
	path := stringField(mapField(kustomization.Document, "spec"), "path")
	if path == "" {
		path = "."
	}
	path = strings.TrimPrefix(path, "./")
	targetPath := filepath.Join(repoRoot, filepath.FromSlash(path))
	manifestPath := filepath.Join(repoRoot, filepath.FromSlash(kustomization.ManifestPath))
	namespace := kustomization.Namespace
	if namespace == "" {
		namespace = "default"
	}
	args := []string{
		"build", "kustomization", kustomization.Name,
		"--namespace", namespace,
		"--path", targetPath,
		"--kustomization-file", manifestPath,
		"--dry-run", "--in-memory-build",
	}
	command := commandOutput(fluxBinary, repoRoot, args...)
	if command.err != nil {
		return nil, fmt.Errorf("render %s (%s): %w\n%s", kustomization.Name, kustomization.ManifestPath, command.err, strings.TrimSpace(command.stderr))
	}
	documents, err := decodeYAMLDocuments(strings.NewReader(command.stdout))
	if err != nil {
		return nil, fmt.Errorf("decode Flux output for %s: %w", kustomization.Name, err)
	}
	scope := clusterScope(kustomization.ManifestPath, kustomization.Document)
	owner := Owner{Kind: "Kustomization", Namespace: kustomization.Namespace, Name: kustomization.Name, Source: "render:" + kustomization.ManifestPath}
	var result []ResourceOwner
	for _, document := range documents {
		identity, ok := resourceIdentity(document, scope)
		if ok {
			result = append(result, ResourceOwner{Identity: identity, Owner: owner})
		}
	}
	return result, nil
}

func inventoryOwners(objects []map[string]any, cluster string) ([]ResourceOwner, error) {
	var result []ResourceOwner
	for _, object := range objects {
		kind := stringField(object, "kind")
		if kind != "Kustomization" && kind != "HelmRelease" {
			continue
		}
		metadata := mapField(object, "metadata")
		owner := Owner{
			Kind:      kind,
			Namespace: stringField(metadata, "namespace"),
			Name:      stringField(metadata, "name"),
			Source:    "status.inventory",
		}
		if owner.Name == "" {
			return nil, fmt.Errorf("%s has no metadata.name", kind)
		}
		entries := sliceField(mapField(mapField(object, "status"), "inventory"), "entries")
		for index, entryValue := range entries {
			entry, ok := entryValue.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("%s %s inventory entry %d is not an object", kind, owner.Name, index)
			}
			identity, ok := inventoryIdentity(entry, cluster)
			if !ok {
				return nil, fmt.Errorf("%s %s inventory entry %d has invalid id %q", kind, owner.Name, index, stringField(entry, "id"))
			}
			result = append(result, ResourceOwner{Identity: identity, Owner: owner})
		}
	}
	return result, nil
}

func formatDuplicates(duplicates map[ResourceIdentity][]Owner) string {
	if len(duplicates) == 0 {
		return "No duplicate resource ownership detected.\n"
	}
	identities := make([]ResourceIdentity, 0, len(duplicates))
	for identity := range duplicates {
		identities = append(identities, identity)
	}
	sort.Slice(identities, func(i, j int) bool {
		return identitySortKey(identities[i]) < identitySortKey(identities[j])
	})

	var builder strings.Builder
	builder.WriteString("Duplicate resource ownership detected:\n")
	for _, identity := range identities {
		fmt.Fprintf(&builder, "- %s\n", identityDisplay(identity))
		owners := append([]Owner(nil), duplicates[identity]...)
		sort.Slice(owners, func(i, j int) bool { return ownerSortKey(owners[i]) < ownerSortKey(owners[j]) })
		for _, owner := range owners {
			fmt.Fprintf(&builder, "  - %s\n", ownerDisplay(owner))
		}
	}
	return builder.String()
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: flux-resource-ownership <repository|inventory> [flags]")
		return 2
	}
	switch args[0] {
	case "repository":
		return runRepository(args[1:], stdout, stderr)
	case "inventory":
		return runInventory(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown command %q\n", args[0])
		return 2
	}
}

func runRepository(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("repository", flag.ContinueOnError)
	flags.SetOutput(stderr)
	repoRoot := flags.String("repo-root", ".", "repository root")
	fluxBinary := flags.String("flux-binary", "flux", "Flux CLI binary")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	absRoot, err := filepath.Abs(*repoRoot)
	if err != nil {
		fmt.Fprintf(stderr, "resolve repository root: %v\n", err)
		return 2
	}
	kustomizations, err := discoverKustomizations(absRoot)
	if err != nil {
		fmt.Fprintf(stderr, "discover Flux Kustomizations: %v\n", err)
		return 2
	}
	var resources []ResourceOwner
	for _, kustomization := range kustomizations {
		owners, err := renderOwnershipKustomization(absRoot, *fluxBinary, kustomization)
		if err != nil {
			fmt.Fprintf(stderr, "%v\n", err)
			return 2
		}
		resources = append(resources, owners...)
	}
	duplicates := findDuplicateOwners(resources)
	output := formatDuplicates(duplicates)
	fmt.Fprint(stdout, output)
	if len(duplicates) > 0 {
		return 1
	}
	return 0
}

func runInventory(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("inventory", flag.ContinueOnError)
	flags.SetOutput(stderr)
	cluster := flags.String("cluster", "default", "cluster scope")
	var inputs stringList
	flags.Var(&inputs, "input", "Kustomization or HelmRelease JSON file; repeatable, or use - for stdin")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	objects, err := loadInventoryObjects(inputs)
	if err != nil {
		fmt.Fprintf(stderr, "load inventory: %v\n", err)
		return 2
	}
	resources, err := inventoryOwners(objects, *cluster)
	if err != nil {
		fmt.Fprintf(stderr, "parse inventory: %v\n", err)
		return 2
	}
	duplicates := findDuplicateOwners(resources)
	fmt.Fprint(stdout, formatDuplicates(duplicates))
	if len(duplicates) > 0 {
		return 1
	}
	return 0
}

type stringList []string

func (list *stringList) String() string { return strings.Join(*list, ",") }

func (list *stringList) Set(value string) error {
	*list = append(*list, value)
	return nil
}

func loadInventoryObjects(inputs []string) ([]map[string]any, error) {
	if len(inputs) == 0 {
		inputs = []string{"-"}
	}
	var result []map[string]any
	for _, input := range inputs {
		var reader io.Reader = os.Stdin
		var file *os.File
		if input != "-" {
			var err error
			file, err = os.Open(input)
			if err != nil {
				return nil, err
			}
			reader = file
		}
		objects, err := decodeJSONObjects(reader)
		if file != nil {
			_ = file.Close()
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", input, err)
		}
		result = append(result, objects...)
	}
	return result, nil
}

func decodeJSONObjects(reader io.Reader) ([]map[string]any, error) {
	decoder := json.NewDecoder(bufio.NewReader(reader))
	var result []map[string]any
	for {
		var value any
		err := decoder.Decode(&value)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		objects, err := flattenObjects(value)
		if err != nil {
			return nil, err
		}
		result = append(result, objects...)
	}
	return result, nil
}

func flattenObjects(value any) ([]map[string]any, error) {
	object, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("JSON document is not an object")
	}
	if items, ok := object["items"].([]any); ok {
		var result []map[string]any
		for index, item := range items {
			itemObject, ok := item.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("items[%d] is not an object", index)
			}
			result = append(result, itemObject)
		}
		return result, nil
	}
	return []map[string]any{object}, nil
}

func decodeYAMLDocuments(reader io.Reader) ([]map[string]any, error) {
	decoder := yaml.NewDecoder(reader)
	var result []map[string]any
	for {
		var document map[string]any
		err := decoder.Decode(&document)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if len(document) != 0 {
			result = append(result, document)
		}
	}
	return result, nil
}

type commandResult struct {
	stdout string
	stderr string
	err    error
}

func commandOutput(binary, dir string, args ...string) commandResult {
	command := execCommand(binary, args...)
	command.Dir = dir
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	return commandResult{stdout: stdout.String(), stderr: stderr.String(), err: err}
}

// execCommand is a variable so command invocation can be replaced by tests if
// a future test needs to exercise render failures without a Flux installation.
var execCommand = func(binary string, args ...string) *exec.Cmd {
	return exec.Command(binary, args...)
}

func isFluxKustomization(document map[string]any) bool {
	return stringField(document, "kind") == "Kustomization" && strings.HasPrefix(stringField(document, "apiVersion"), "kustomize.toolkit.fluxcd.io/")
}

func stringField(object map[string]any, field string) string {
	value, ok := object[field]
	if !ok {
		return ""
	}
	valueString, ok := value.(string)
	if !ok {
		return ""
	}
	return valueString
}

func mapField(object map[string]any, field string) map[string]any {
	value, ok := object[field]
	if !ok {
		return nil
	}
	valueMap, ok := value.(map[string]any)
	if !ok {
		return nil
	}
	return valueMap
}

func sliceField(object map[string]any, field string) []any {
	value, ok := object[field]
	if !ok {
		return nil
	}
	valueSlice, ok := value.([]any)
	if !ok {
		return nil
	}
	return valueSlice
}

func identitySortKey(identity ResourceIdentity) string {
	return strings.Join([]string{identity.Cluster, identity.Group, identity.Kind, identity.Namespace, identity.Name}, "\x00")
}

func ownerSortKey(owner Owner) string {
	return strings.Join([]string{owner.Kind, owner.Namespace, owner.Name, owner.Source}, "\x00")
}

func identityDisplay(identity ResourceIdentity) string {
	group := identity.Group
	if group == "" {
		group = "core"
	}
	namespace := identity.Namespace
	if namespace == "" {
		namespace = "<cluster-scoped>"
	}
	return strings.Join([]string{identity.Cluster, group, identity.Kind, namespace, identity.Name}, "/")
}

func ownerDisplay(owner Owner) string {
	location := owner.Name
	if owner.Namespace != "" {
		location = owner.Namespace + "/" + owner.Name
	}
	if owner.Source == "" {
		return owner.Kind + " " + location
	}
	return owner.Kind + " " + location + " [" + owner.Source + "]"
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}
