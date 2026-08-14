# Manifest policy testing

The Go test suite is the CI and local entry point for semantic manifest policy
checks. It renders the repository's Kustomizations, evaluates the embedded
policies, and runs the related Go contract tests.

## Prerequisites

Install Kustomize and make the binary available on `PATH`:

```sh
go install sigs.k8s.io/kustomize/kustomize/v5@v5.8.1
```

The exact Kustomize version used by local development should match the version
configured in CI when possible. Kustomize is required because the tests render
Kustomizations before evaluating their policies.

## Run the manifest policy tests

From the repository root, run:

```sh
go test ./...
```

These tests require no Kubernetes cluster or cluster credentials. They operate
on repository files and local Kustomize output. A Kustomization that refers to
a remote base or resource may require network access during rendering.

## Check Flux resource ownership

The repository ownership checker is a separate check from the semantic policy
suite. With the Flux CLI available, run:

```sh
go run ./tests repository --repo-root .
```

This command checks that a rendered resource is not assigned to multiple Flux
owners. Its ownership model and runtime inventory check are documented in
[Flux resource ownership](flux-resource-ownership.md).

## Flux Schema validation

Flux Schema validation is a separate structural validation check. It remains
responsible for schema-level concerns such as field types, required fields,
unknown fields, and other configured resource schema constraints. The Go
manifest policy suite owns repository-specific semantic checks and does not
duplicate Flux Schema validation. The CI workflow runs the configured Flux
Schema setup and validation action after the Go and ownership checks.

## celld deployment contract

The celld deployment is covered by the `TestCelldSemanticPolicies` suite and
the embedded `tests/policies/celld.rego` module. The policy contract checks the
Ceph RGW bucket resources, vcluster Service and Secret mappings, StatefulSet
runtime and security settings, client/peer port separation, disruption budget,
and Tailscale-only Ingress. The former shell-based celld manifest test is no
longer required; run `go test ./...` for the policy entry point.
