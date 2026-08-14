package main

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

func TestPolicyEvaluatorReturnsNoViolations(t *testing.T) {
	evaluator, err := NewPolicyEvaluator()
	if err != nil {
		t.Fatal(err)
	}

	violations, err := evaluator.Evaluate(context.Background(), PolicyInput{
		Resources: []PolicyResource{{
			Source:   "clusters/home/example.yaml",
			Document: map[string]any{"kind": "ConfigMap"},
		}},
		SourceFiles: []string{"clusters/home/example.yaml"},
		Context:     map[string]any{"test_violation": false},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(violations) != 0 {
		t.Fatalf("violations = %#v, want none", violations)
	}
}

func TestPolicyEvaluatorDecodesViolations(t *testing.T) {
	evaluator, err := NewPolicyEvaluator()
	if err != nil {
		t.Fatal(err)
	}

	violations, err := evaluator.Evaluate(context.Background(), PolicyInput{
		Context: map[string]any{"test_violation": true},
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []PolicyViolation{{
		Policy:   "runner-test-policy",
		Resource: "test/resource",
		Message:  "test violation",
	}}
	if !reflect.DeepEqual(violations, want) {
		t.Fatalf("violations = %#v, want %#v", violations, want)
	}
}

func TestPolicyEvaluatorRejectsMalformedPolicy(t *testing.T) {
	_, err := newPolicyEvaluatorFromModules(map[string]string{
		"broken.rego": "package manifest_policy\nviolations contains if",
	})
	if err == nil {
		t.Fatal("newPolicyEvaluatorFromModules accepted malformed policy")
	}
}

func TestFormatPolicyViolationsIsDeterministic(t *testing.T) {
	violations := []PolicyViolation{
		{Policy: "z-policy", Resource: "resource-b", Path: "spec.items[1]", Message: "second"},
		{Policy: "a-policy", Resource: "resource-z", Path: "metadata.name", Message: "first"},
		{Policy: "a-policy", Resource: "resource-a", Path: "", Message: "third"},
	}

	got := FormatPolicyViolations(violations)
	want := strings.Join([]string{
		"a-policy resource-a: third",
		"a-policy resource-z metadata.name: first",
		"z-policy resource-b spec.items[1]: second",
	}, "\n")
	if got != want {
		t.Fatalf("formatted violations = %q, want %q", got, want)
	}
}
