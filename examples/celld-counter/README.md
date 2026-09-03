# celld Durable Object Counter

This is a small Worker example for the celld Fleet. It stores one counter in a
SQLite-backed Durable Object named `demo`.

## Behavior

- `GET /` returns the current value, for example `{"count":0}`.
- `POST /` increments the value and returns it, for example `{"count":1}`.
- Other paths return `404`.
- Other methods at `/` return `405`.

## Run the tests

This project has no third-party dependencies:

```bash
npm test
```

## Deploy to the celld Fleet

Deployment is an operator-only operation because it uses the same object-store
credentials as the celld runtime. First follow
[`docs/celld-kubernetes-setup.md`](../../docs/celld-kubernetes-setup.md) to
verify the Kubernetes contexts, wait for the Fleet and bucket, inject
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` through the approved secret
delivery process, and start the temporary RGW port-forward.

Do not put credentials in this directory, shell history, Git, CI, or command
output. From this directory, deploy to the same bucket and region used by the
Fleet:

```bash
celld deploy . \
  --bucket s3://celld \
  --endpoint http://127.0.0.1:18080 \
  --region us-east-1
```

Close the port-forward after deployment. Do not expose the RGW or celld peer
port publicly.

## Verify the deployed Worker

Use the Tailscale hostname returned by the celld Ingress. Replace the example
hostname below with the actual address and run these requests from a device
connected to Tailscale:

```bash
CELLD_URL=https://celld.example.ts.net
curl --fail-with-body "$CELLD_URL/"
curl --fail-with-body --request POST "$CELLD_URL/"
curl --fail-with-body "$CELLD_URL/"
```

The final request should show the value produced by the POST request. The
Ingress and post-deployment checks are documented in the existing runbook.
