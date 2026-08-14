package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"path/filepath"
	"sort"
	"strings"

	"github.com/open-policy-agent/opa/rego"
)

//go:embed policies/*.rego
var embeddedPolicyFiles embed.FS

type PolicyResource struct {
	Source   string         `json:"source"`
	Document map[string]any `json:"document"`
}

type PolicyInput struct {
	Resources   []PolicyResource `json:"resources"`
	SourceFiles []string         `json:"sourceFiles"`
	Context     map[string]any   `json:"context"`
}

type PolicyViolation struct {
	Policy   string `json:"policy"`
	Resource string `json:"resource"`
	Path     string `json:"path"`
	Message  string `json:"message"`
}

type PolicyEvaluator struct {
	query rego.PreparedEvalQuery
}

func NewPolicyEvaluator() (*PolicyEvaluator, error) {
	modules := make(map[string]string)
	err := fs.WalkDir(embeddedPolicyFiles, "policies", func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || filepath.Ext(path) != ".rego" {
			return nil
		}
		module, err := embeddedPolicyFiles.ReadFile(path)
		if err != nil {
			return err
		}
		modules[path] = string(module)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("load embedded policies: %w", err)
	}
	return newPolicyEvaluatorFromModules(modules)
}

func newPolicyEvaluatorFromModules(modules map[string]string) (*PolicyEvaluator, error) {
	filenames := make([]string, 0, len(modules))
	for filename := range modules {
		filenames = append(filenames, filename)
	}
	sort.Strings(filenames)

	options := []func(*rego.Rego){rego.Query("data.manifest_policy.violations")}
	for _, filename := range filenames {
		options = append(options, rego.Module(filename, modules[filename]))
	}
	query, err := rego.New(options...).PrepareForEval(context.Background())
	if err != nil {
		return nil, fmt.Errorf("prepare policy query: %w", err)
	}
	return &PolicyEvaluator{query: query}, nil
}

func (e *PolicyEvaluator) Evaluate(ctx context.Context, input PolicyInput) ([]PolicyViolation, error) {
	result, err := e.query.Eval(ctx, rego.EvalInput(input))
	if err != nil {
		return nil, fmt.Errorf("evaluate policies: %w", err)
	}
	if len(result) == 0 || len(result[0].Expressions) == 0 {
		return nil, nil
	}

	encoded, err := json.Marshal(result[0].Expressions[0].Value)
	if err != nil {
		return nil, fmt.Errorf("encode policy violations: %w", err)
	}
	var violations []PolicyViolation
	if err := json.Unmarshal(encoded, &violations); err != nil {
		return nil, fmt.Errorf("decode policy violations: %w", err)
	}
	sortPolicyViolations(violations)
	return violations, nil
}

func FormatPolicyViolations(violations []PolicyViolation) string {
	ordered := append([]PolicyViolation(nil), violations...)
	sortPolicyViolations(ordered)

	lines := make([]string, 0, len(ordered))
	for _, violation := range ordered {
		location := strings.TrimSpace(strings.Join([]string{violation.Policy, violation.Resource, violation.Path}, " "))
		lines = append(lines, fmt.Sprintf("%s: %s", location, violation.Message))
	}
	return strings.Join(lines, "\n")
}

func sortPolicyViolations(violations []PolicyViolation) {
	sort.Slice(violations, func(i, j int) bool {
		left, right := violations[i], violations[j]
		if left.Policy != right.Policy {
			return left.Policy < right.Policy
		}
		if left.Resource != right.Resource {
			return left.Resource < right.Resource
		}
		if left.Path != right.Path {
			return left.Path < right.Path
		}
		return left.Message < right.Message
	})
}
