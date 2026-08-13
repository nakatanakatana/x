package manifest_policy

import rego.v1

violations contains {
	"policy": "runner-test-policy",
	"resource": "test/resource",
	"message": "test violation",
} if input.context.test_violation == true
