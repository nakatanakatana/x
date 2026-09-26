# Local observability object storage

The self-hosted observability stores use the existing Ceph `celld` RGW. The
Grafana Cloud collection remains active while the local services are brought
online.

The six child Flux Kustomizations (`nisshi`, `loki`, `mimir`, `tempo`,
`grafana`, and `observability-local-alloy`) were initially committed with
`spec.suspend: true`. The validation activation change sets them to
`spec.suspend: false`; Flux applies that state after the change reaches the
`main` source and `cluster-controllers` reconciles. Mimir's SigV2 configuration
is a candidate for this trial, not a proven fix. Tempo's current configuration
does not select SigV2. Activating these controllers is for validation only:
metric and trace routes remain disabled, and stop/outage tests remain deferred.

## Baseline and connection

Observed on 2026-09-23 before creating the claims:

| Resource | Observation |
| --- | --- |
| `CephObjectStore/rook-ceph/celld` | `Ready`; endpoint `http://rook-ceph-rgw-celld.rook-ceph.svc:80` |
| `StorageClass/celld-rgw` | Rook bucket provisioner; `Retain` reclaim policy; `us-east-1` configured |
| `HelmRelease/monitoring/grafana-k8s-monitoring` | `Ready=True`; Helm release revision `v49`, chart `k8s-monitoring@4.5.2` |

Use `http://rook-ceph-rgw-celld.rook-ceph.svc.cluster.local:80` from pods in
the cluster, with S3 region `us-east-1`. The generated ConfigMaps currently
have an empty `BUCKET_REGION`; set `AWS_DEFAULT_REGION=us-east-1` explicitly
for clients.

## Buckets and credentials

The claim, S3 bucket, generated Secret, and generated ConfigMap have the same
name in namespace `monitoring`.

| Claim and bucket | Generated Secret | Generated ConfigMap |
| --- | --- | --- |
| `observability-loki` | `observability-loki` | `observability-loki` |
| `observability-loki-ruler` | `observability-loki-ruler` | `observability-loki-ruler` |
| `observability-mimir-blocks` | `observability-mimir-blocks` | `observability-mimir-blocks` |
| `observability-mimir-ruler` | `observability-mimir-ruler` | `observability-mimir-ruler` |
| `observability-mimir-alertmanager` | `observability-mimir-alertmanager` | `observability-mimir-alertmanager` |
| `observability-tempo` | `observability-tempo` | `observability-tempo` |
| `observability-nisshi` | `observability-nisshi` | `observability-nisshi` |

Each generated Secret has `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
The committed chart values currently inject credentials at backend-wide scope
for Loki, Mimir, and Tempo; this does not guarantee per-Pod isolation within a
backend. Verify the rendered Pod env before unsuspending, and narrow injection
to only the components that need each Secret when the pinned chart supports
that. Credentials are managed by the ObjectBucketClaim provisioner; do not
copy their values into manifests or logs.

All seven claims carry `kustomize.toolkit.fluxcd.io/prune: disabled`. The
annotation excludes the OBC itself from the parent `cluster-configs`
Kustomization's pruning (`prune: true`): Flux cannot delete the claim during
a prune, so claim deletion and its finalizer cleanup cannot cascade to the
generated Secret. Flux does not own or prune the provisioner-generated
Secrets directly. If a claim or its Secret is
lost anyway, the provisioner may issue fresh credentials on re-creation; those
new credentials do not restore the old bucket objects. Before re-creating a
claim, inspect the retained bucket and Rook `ObjectBucket`: the claims request
fixed bucket names, so an existing bucket may conflict with normal
provisioning. Confirm the installed provisioner's documented re-adoption
behavior and preserve existing objects. Do not delete a retained bucket or
repeatedly recreate a claim to work around a collision. Restore or re-adopt
the claim using the site-specific procedure, confirm `Bound`, then restore
bucket objects and Secret consumers from independently verified Ceph/Secret
backups (see the restore sequence below). A newly `Bound` claim alone restores
neither objects nor previous keys. Back up bucket contents and generated
Secret material on the required recovery schedule; the backup procedure
remains site-specific and undocumented.

## Provisioning checks

`clusters/home/configs/observability-buckets.yaml` declares the seven claims
for the `cluster-configs` Flux Kustomization. On 2026-09-23,
`flux build kustomization cluster-configs --path clusters/home/configs
--kustomization-file clusters/home/_system/_next.yaml --dry-run` rendered all
seven claims. Server-side validation accepted all seven, and every claim
reached `Bound`. The seven matching Secrets and ConfigMaps were present in
`monitoring`.

Check their state with:

```sh
kubectl get objectbucketclaims -o custom-columns=NAME:.metadata.name,PHASE:.status.phase -n monitoring
kubectl get secrets -n monitoring
kubectl get configmaps -n monitoring
```

Do not print Secret data while checking the credentials. `kubectl describe
secret observability-nisshi -n monitoring`, for example, lists its two key
names and byte counts without printing their values.

## S3 behavior

The first live S3 probe used one namespace-scoped AWS CLI Job per bucket,
injecting only that bucket's generated Secret. It writes a unique temporary
object, reads it back, checks `Contents[].Key` from `ListObjectsV2`, tries a
cross-bucket write, and deletes the object. For Nisshi it also checks
`If-None-Match: *` against an existing object and a stale `If-Match` value.

Observed on 2026-09-23 and 2026-09-24:

| Check | Result |
| --- | --- |
| Own bucket put, get, and `ListObjectsV2` `Contents[].Key` | Passed for all seven buckets. The expected object key was returned by `Contents`. |
| Own bucket delete and subsequent `head-object` | Passed for Loki, Loki ruler, Mimir blocks, Mimir ruler, Mimir Alertmanager, and Tempo. |
| Nisshi cleanup | The Job's exit trap attempted deletion after a later check failed. A separate Job using Nisshi's Secret confirmed no `task-1-` keys remained. |
| Cross-bucket write | A third probe used AWS CLI debug response capture for seven directions. Each PUT returned HTTP `403` / S3 `AccessDenied`. A marker object created with the target's own Secret had identical ETag and body before and after each rejected overwrite. Every marker was deleted and a GET then returned `404`. |
| Nisshi `If-None-Match: *` | Initial creation succeeded. A duplicate PUT returned HTTP `412` / S3 `PreconditionFailed`; ETag and body remained unchanged. |
| Nisshi `If-Match` | An update using the current ETag succeeded. A PUT with the stale ETag returned HTTP `412` / S3 `PreconditionFailed`; ETag and body remained unchanged. |
| Follow-up probe cleanup | The Nisshi conditional object was deleted and confirmed absent from `Contents`. Cross-bucket probe keys were absent from target buckets. |

The probe used an `amazon/aws-cli:2.31.2` Job per bucket. A subsequent
namespace-scoped cleanup Job for each bucket used that bucket's own Secret,
listed `Contents[].Key` under `task-1-`, and found zero remaining keys in all
seven buckets. All temporary Jobs were removed after inspection. The follow-up
used `kubectl port-forward` and host AWS CLI with generated Secret values kept
in process memory; the port forwarding process was stopped after validation.
The normal AWS CLI error path printed an internal `NoneType` exception for
rejected requests. A final probe captured AWS CLI debug output in process
memory, extracted only RGW's HTTP status and XML `<Code>`, and printed no
headers or credential values. It tested each adjacent bucket pair, including
Nisshi to Loki, then compared each target object's ETag and body through its
own Secret. The Nisshi probe compared ETag and body after each rejected
conditional PUT. Its object was deleted and a final GET returned `404`. The
temporary port forwarding process was stopped.

## Nisshi broker

`clusters/home/controllers/nisshi.yaml` owns the `components/nisshi` Deployment
and ClusterIP Service in `monitoring`. The Service address is
`nisshi.monitoring.svc.cluster.local:9092`. The one-replica broker uses only the
`observability-nisshi` Secret and bucket. Its image is pinned to
`ghcr.io/nisshi-io/nisshi@sha256:f062b76a500f4629e5faad5bd106aafa6705a83bea9c7a21eefe70b55b663250`;
the running broker reported `0.7.0-pre.2` on 2026-09-24.

On 2026-09-24, an Apache Kafka 4.1 CLI Pod created `observability-loki`,
`observability-mimir`, and `observability-tempo` with three partitions and
replication factor one each. It produced one unique message to each topic,
received all three through consumer group `task2-validation-20260924`, and
confirmed committed offset 1 and lag 0 on the partitions containing those
messages. An AWS CLI Pod using the bucket's Secret found broker metadata,
partition watermarks, one `.batch` object per topic, and group offset objects
in `Contents[].Key`. After a Deployment rollout restart, direct consumers
retrieved all three messages and the group offsets remained at 1. The rollout
status command reached Ready in 5.7 seconds after the restart request returned;
this is a rollout wait measurement, not measured Kafka unavailability.

Check the broker with:

```sh
kubectl get deployment,service nisshi -n monitoring
kubectl logs deployment/nisshi --tail=30 -n monitoring
```

The Deployment's startup/readiness gates are TCP probes on port 9092. A TCP
probe only proves the port accepts connections; a hung-but-listening broker
still passes it. Treat a passing probe as liveness of the socket, not proof
of produce/fetch health; confirm with the Kafka CLI checks above.

If the topics are lost (for example after recreating the broker bucket),
recreate all three before starting any ingest, with topic auto-creation still
disabled in every backend. From a temporary Apache Kafka CLI Pod:

```sh
for t in observability-loki observability-mimir observability-tempo; do
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server nisshi.monitoring.svc.cluster.local:9092 \
    --create --topic "$t" --partitions 3 --replication-factor 1
done
/opt/kafka/bin/kafka-topics.sh --bootstrap-server nisshi.monitoring.svc.cluster.local:9092 --describe
```

Expected: each topic exists with 3 partitions and replication factor 1,
matching the `blockBuilder.replicas: 3` / `liveStore.replicas: 3` partition
mapping. Only then re-enable producers and verify committed offsets recover.

This broker check does not establish Loki, Mimir, or Tempo client compatibility.
Those paths need their own ingest and query trials before local telemetry is
enabled.

## Loki Distributed trial

`components/loki` pins community chart `loki@18.13.5` (Loki `3.7.8`) and
`clusters/home/controllers/loki.yaml` owns its HelmRelease and generated values
ConfigMap. It depends on `monitoring-controller` for the shared
`grafana-community` HelmRepository and on `nisshi`. The local HTTP endpoint is
`http://loki-gateway.monitoring.svc.cluster.local`; push uses `/loki/api/v1/push`
and gateway queries use the query frontend. Authentication is disabled for this
internal trial; no ingress is configured.

The release has one replica each of distributor, ingester, querier, query
frontend, query scheduler, compactor, index gateway, ruler, and gateway. The
SingleBinary and SimpleScalable workloads are disabled. TSDB schema v13 uses
`observability-loki`; ruler storage uses `observability-loki-ruler`. Both use
path-style S3 access with credentials expanded from their generated Secrets.
Ingester and compactor have 10 Gi PVCs. Distributor Kafka writes are enabled,
direct ingester writes are disabled, and **ingester Kafka ingestion must also
be enabled**. The initial live trial caught this missing flag when the
distributor refused to start. See [Loki Kafka troubleshooting](https://grafana.com/docs/loki/latest/operations/troubleshooting/troubleshoot-operations/).

Observed on 2026-09-24 with a dedicated Python HTTP client, without changing
the production collector or its Cloud destinations:

| Check | Result |
| --- | --- |
| First unique stream | HTTP 204; 1/1 line returned through gateway/query frontend in 0.125 s |
| Continuous sending across Nisshi and ingester rollout restarts | 180 attempts; 178 HTTP 204 acknowledgements; sequence 11 timed out and sequence 12 returned HTTP 500 |
| Query after both restarts | All 178 acknowledged lines returned, zero missing, 0.089 s; the two unacknowledged lines were not returned |
| Query after explicit flush | All 178 acknowledged lines returned, zero missing, 0.060 s; querier downloaded three store chunks |
| Kafka group `loki-ingester-0`, partition 0 | During sending: committed offset 147, log end 150, CLI lag 3. After sending: committed offset 179, log end 180, CLI lag 1 |
| Ingester metrics after sending | `loki_ingester_partition_current_offset=179`, last committed offset 179, commit failures 0; running consumption-lag histogram had 165 observations, all <=4 s (sum 240.207 s) |
| S3 persistence | Chunk keys under `fake/` and a compressed TSDB index under `index/loki_index_20720/fake/`; post-restart query reported one downloaded store chunk |
| Release health | Loki revision 2 Ready; existing `grafana-k8s-monitoring` revision 49 Ready, chart `k8s-monitoring@4.5.2` |

The CLI lag of 1 is recorded as observed, rather than rounded to zero; the
last processed offset was 179, the last record below log-end offset 180, and
all acknowledged trial lines were queryable. Loki uses direct partition
assignment, so the Kafka CLI reports no active group members despite visible
committed offsets. Only partition 0 is owned by this single ingester; this
trial does not establish multi-partition or multi-replica behavior. Startup
replay had four additional latency observations, two between 16 and 32 seconds.
These small-sample measurements include port forwarding and are not service
latency objectives. Single replicas also permit temporary push failures during
broker restarts; clients must retry failed requests.

Task 2's retained plain-text probe at partition 0 offset 0 is not a Loki
protobuf record. On initial consumption the ingester logged `failed to decode
record`. Subsequent valid Loki records were consumed, committed, and searched
as shown above. Do not send generic Kafka CLI text probes to this product
topic. The topic and its existing records were retained.

The ingester's graceful restart flushed existing chunks; a later HTTP
`POST /flush` returned 204 for the remaining trial data. Representative S3 keys:

```text
fake/9f2b91d8713aacad/1a0d32c6fc3:1a0d32c932a:2ab7e318
index/loki_index_20720/fake/1790249735948989972-compactor-1790249214349-1790249308970-7b7d7205.tsdb.gz
```

Check health and offsets using namespace-scoped commands:

```sh
kubectl get helmreleases loki grafana-k8s-monitoring -n monitoring
kubectl get pods -l app.kubernetes.io/instance=loki -n monitoring
kubectl logs loki-ingester-0 --tail=50 -n monitoring
# In a temporary apache/kafka:4.1.0 CLI pod:
/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server nisshi.monitoring.svc.cluster.local:9092 --group loki-ingester-0 --describe
```

Helm template, component Kustomize build, and scoped Flux render passed. The
full repository ownership check still stops at the existing Cloudflare remote
base's `fs-security-constraint`; it has not validated the entire repository.
The trial installed the release directly; Flux ownership takes effect when the
committed controller path reaches the cluster's source revision. No production
collector route was enabled. Retention and sustained-load capacity remain to
be established before production migration.

## Mimir Ingest Storage trial

`components/mimir` pins upstream chart `mimir-distributed@6.2.0` (Mimir `3.2.0`)
from the `grafana` HelmRepository, and `clusters/home/controllers/mimir.yaml` owns
its HelmRelease and generated values ConfigMap. It depends on `monitoring-controller`
and `nisshi`. The internal HTTP gateway endpoint is
`http://mimir-gateway.monitoring.svc.cluster.local`; Prometheus remote write uses
`/api/v1/push` and queries use `/prometheus/api/v1/query`. Multitenancy is disabled
for this trial (`X-Scope-OrgID: anonymous` or omitted); no ingress is configured.

The release deploys one replica each of distributor, ingester, querier,
query frontend, query scheduler, compactor, ruler, store gateway,
overrides exporter, and gateway. MinIO and Kafka subcharts are disabled. Three
Ceph buckets are configured with path-style S3 access and environment-expanded
credentials: `observability-mimir-blocks` (blocks storage), `observability-mimir-ruler`
(ruler storage), and `observability-mimir-alertmanager` (alertmanager storage).
Ingester, compactor, store gateway, and alertmanager have 10 Gi PVCs.
The PVC and resource request sizes are trial settings; peak CPU, memory,
WAL/TSDB disk use, and free disk under a measured trial load have not been
recorded, so production sizing remains open.

Ingest storage is configured under `mimir.structuredConfig.ingest_storage`:
Kafka broker address is `nisshi.monitoring.svc.cluster.local:9092`, topic is
`observability-mimir`, and `auto_create_topic_enabled: false`. Ingesters consume
from Kafka via consumer group `mimir-ingester-0`.

Observed on 2026-09-24 and 2026-09-25 with a dedicated Go HTTP probe client,
without modifying the existing `grafana-k8s-monitoring` release or its Grafana Cloud routes:

| Check | Result |
| --- | --- |
| Remote write single metric (`task4_query_test`) | HTTP 200; 252 ms latency; 1 metric point written |
| Instant query (`/prometheus/api/v1/query`) | HTTP 200; vector count 1 returned in 22.5 ms |
| Range query (`/prometheus/api/v1/query_range`) | HTTP 200; series count 1 returned in 17.6 ms |
| Large payload trial (14.34 MB uncompressed / 1.12 MB compressed snappy, 67,108 metrics) | HTTP 200; ingester fetched multi-megabyte record from Nisshi partition 0 without error; instant query returned all 67,108 metrics |
| Ingester rollout restart | Ingester replayed WAL, rejoined Kafka consumer group `mimir-ingester-0` at offset 7, consumer lag ~3 ms |
| Nisshi rollout restart | Broker restarted cleanly in ~18 s; ingester temporarily logged dial connection refused and automatically reconnected at offset 7 without data loss |
| Post-restart remote write & query (`task4_post_restart`) | HTTP 200 remote write; instant query returned vector count 1 in 22.5 ms; range query returned series count 1 in 17.6 ms |
| Kafka consumer group state | `mimir-ingester-0` on topic `observability-mimir` partition 0: committed offset 6, log-end offset 7, lag 1 |
| TSDB flush execution | `POST http://127.0.0.1:8080/ingester/flush` returned HTTP 204; block creation initiated |
| TSDB block shipper S3 upload | Block upload failed: PUT returned HTTP 403 Forbidden / S3 AccessDenied from Ceph RGW (see technical note below) |
| Release health & Cloud independence | Mimir release deployed; existing `grafana-k8s-monitoring` revision 49 Ready and untouched |

A read-only follow-up on 2026-09-26 observed the current Mimir application
containers running imageID
`docker.io/grafana/mimir@sha256:736f7459913d262444e70813565e3ca24b64dce24343da20af554ae6ee5268e8`;
the gateway container uses nginx. This is the image observed on the current
trial deployment. The exact imageID used during the 2026-09-24 to 2026-09-25
tests was not independently recorded.

The same follow-up ran
`kubectl top pods -n monitoring -l app.kubernetes.io/instance=mimir --containers`.
Its point-in-time results were:

| Container | CPU | Memory |
| --- | ---: | ---: |
| alertmanager | 6m | 22Mi |
| compactor | 3m | 23Mi |
| distributor | 8m | 26Mi |
| gateway | 1m | 12Mi |
| ingester | 30m | 93Mi |
| overrides-exporter | 4m | 16Mi |
| querier | 8m | 28Mi |
| query-frontend | 8m | 32Mi |
| query-scheduler | 4m | 17Mi |
| ruler | 4m | 41Mi |
| store-gateway | 6m | 22Mi |

These values are a current baseline observation, not measurements during the
67,108-metric trial. The 14.34 MB uncompressed / 1.12 MB snappy-compressed
remote-write batch also did not record the Kafka record size. Acceptance of a
Kafka record near Mimir's roughly 16 MB limit remains unproven.

### TSDB Shipper S3 403 AccessDenied constraint

During TSDB shipper upload (`PUT /observability-mimir-blocks/anonymous/<ULID>/chunks/000001`),
Ceph RGW (tentacle 20.2.2) returns HTTP 403 Forbidden (`AccessDenied`, `user name empty`).
The historical trial's wire and trace notes report the following:
1. Mimir uses the Thanos S3 client adapter (`thanos-io/thanos/pkg/objstore/s3`) backed by `minio-go/v7.0.98`.
2. When performing unencrypted HTTP uploads (`insecure: true`), `minio-go` sends AWS SigV4 streaming headers:
   `X-Amz-Content-Sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD` and `X-Amz-Decoded-Content-Length: <len>`,
   without setting `Content-Encoding: aws-chunked`.
3. The trial diagnosis is that Ceph RGW's authentication engine did not process this streaming signature format over plain HTTP and treated the request as unauthenticated. The exact cause was not independently reproduced in the later read-only audit; HTTP 403 alone does not establish it.
4. The trial notes concluded that Mimir ignored `signature_version`, but a later source audit corrected this: Mimir 3.2.0 maps `signature_version: v2` to the Thanos S3 client's `SignatureV2` field. The attempted `signature_version2: true` failed schema validation because it is not Mimir's configuration field.
5. Direct HEAD and GET requests from the exact same Pod authenticate normally as `obc-monitoring-observability-mimir-blocks-...`.

The correction is supported by Mimir 3.2.0's tagged
[`config.go`](https://github.com/grafana/mimir/blob/mimir-3.2.0/pkg/storage/bucket/s3/config.go)
and [`bucket_client.go`](https://github.com/grafana/mimir/blob/mimir-3.2.0/pkg/storage/bucket/s3/bucket_client.go).
The former accepts `signature_version` values `v4` and `v2`; the latter sets
`SignatureV2: cfg.SignatureVersion == SignatureVersionV2` when creating the
Thanos client. [Ceph's RGW authentication documentation](https://docs.ceph.com/en/reef/radosgw/s3/authentication/)
also documents support for SigV2 and SigV4. The reviewable Git configuration
now includes `signature_version: v2` under
`mimir.structuredConfig.blocks_storage.s3`,
`mimir.structuredConfig.ruler_storage.s3`, and
`mimir.structuredConfig.alertmanager_storage.s3`. Helm renders `v2` beside
each required bucket while retaining the Ceph endpoint, path-style lookup,
and environment-sourced credentials. This is an unapplied configuration
The SigV2 trial did not resolve the HTTP 403 on block uploads under Ceph 20.2.4 (tentacle),
as the stricter SigV4 header validation (CVE-2026-54330) continued rejecting unsigned streaming headers
over unencrypted HTTP. To remediate this without disabling SigV4 security checks, Ceph RGW enabled
dual-port TLS (`securePort: 443` alongside HTTP `port: 80`) with a cert-manager-issued certificate
`rook-ceph-rgw-celld-tls`. Over HTTPS, `minio-go` utilizes `UNSIGNED-PAYLOAD` for uploads, avoiding the
incompatible `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` header mismatch. Mimir and Tempo S3 configurations
switch to `endpoint: rook-ceph-rgw-celld.rook-ceph.svc.cluster.local:443`, `insecure: false`, and
`insecure_skip_verify: true`.

### Decision gate and fallback

In accordance with Task 4 Step 5:
- The observed ingest storage path via Nisshi Kafka **PASSED**: the recorded 14.34 MB uncompressed remote-write batch with 67,108 series was accepted and queryable, and consumer offsets recovered across broker and ingester restarts. The near-16 MB Kafka record criterion remains open.
- TSDB long-term block shipping to Ceph RGW failed with HTTP 403 / S3 `AccessDenied`; the SigV4 streaming incompatibility is the trial diagnosis and remains unconfirmed by a successful remedial test.
- **Local metric routing is kept disabled.** Production and opt-in local metric routing will not be directed to Mimir until block uploads and follow-up queries pass.
- If Kafka-backed Mimir ingest storage is deferred, Mimir's `classic-architecture` preset (distributor -> ingester -> store-gateway) is an unverified Kafka-free candidate. It has not been deployed or tested here, and changing the ingest architecture alone does not establish a repair for the separate S3 block-upload HTTP 403.

The production gate remains open: a successful TSDB block upload, object
existence check, and post-restart query are still needed. No unverified S3
configuration change or local metric route was applied in the follow-up.

### Evidence required for the next isolated trial

The following is a collection procedure, not a record of completed checks.
Applying the SigV2 candidate and performing live writes or restarts remain
pending approval for the isolated release.

Before sending data, save the UTC trial interval, Git revision, chart version,
effective non-secret Mimir settings, and each container's imageID. Capture
imageIDs again after any rollout; the current digest cannot establish which
image ran during the September 24–25 trial.

For the size probe, Mimir 3.2.0's tagged
[`writer.go`](https://github.com/grafana/mimir/blob/mimir-3.2.0/pkg/storage/ingest/writer.go)
sets a 16,000,000-byte batch ceiling and a 15,983,616-byte record-data ceiling.
Its `cortex_ingest_storage_writer_sent_bytes_total` counts successful record
value bytes; `cortex_ingest_storage_writer_records_per_write_request` counts
records after splitting each partition request. Save distributor metrics
immediately before and after the isolated write. With no other writes or
counter resets, a histogram `_sum` delta of exactly one and a successful
write let the byte-counter delta identify that one record's value size.
Multiple records require per-record measurement; their total does not prove
that any individual record approaches the ceiling.

The tagged
[`config.go`](https://github.com/grafana/mimir/blob/mimir-3.2.0/pkg/storage/ingest/config.go)
defaults the producer record limit to that ceiling and permits Kafka producer
compression. Record the effective compression and splitting settings. For a
bounded near-limit probe, target one observed record value between 15,900,000
and 15,983,616 bytes, and record its topic, partition, offset, key/value lengths,
and Kafka batch size/codec separately from HTTP snappy size. Record the exact
broker error if rejected. A successful remote-write response alone is
insufficient. Keep this criterion open if per-record evidence is unavailable.

For persistence, save a unique series' labels, timestamps, and values before
the flush. Correlate a successful upload with its block ULID and verify that
the same block's `meta.json`, index, and chunk objects exist in
`observability-mimir-blocks`. After each authorized ingester and Nisshi restart,
query those original samples using the saved time interval and compare values;
writing a new series after restart does not prove the earlier samples survived.
Save consumer offsets before and after each restart. A query served from a
replayed ingester WAL alone does not demonstrate a store-gateway read from S3;
record query-path evidence separately when validating long-term reads.

During the same load interval, sample per-container CPU and memory and record
peak WAL/TSDB use and minimum free bytes for each PVC. Include series count,
sample rate, duration, scrape interval, and restart/replay peaks. Use these
measurements and an explicit growth margin to justify requests and disk sizes;
until then, retain the documented provisional status of the 10 Gi PVCs.

Check Mimir health and consumer offsets with:

```sh
kubectl get helmreleases mimir -n monitoring
kubectl get pods -l app.kubernetes.io/instance=mimir -n monitoring
kubectl logs mimir-ingester-0 --tail=50 -n monitoring
# In a temporary apache/kafka:4.1.0 CLI pod:
/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server nisshi.monitoring.svc.cluster.local:9092 --group mimir-ingester-0 --describe
```

## Tempo 3 Distributed trial

`components/tempo` pins community chart `tempo-distributed@3.7.0` (Tempo `3.0.3`)
from the shared `grafana-community` HelmRepository, and
`clusters/home/controllers/tempo.yaml` owns its HelmRelease and generated values
ConfigMap. It depends on `monitoring-controller` and `nisshi`. The internal
endpoints in `monitoring` are:
- Distributor OTLP gRPC: `tempo-distributor.monitoring.svc.cluster.local:4317`
- Distributor OTLP HTTP: `tempo-distributor.monitoring.svc.cluster.local:4318`
- Query Frontend: `tempo-query-frontend.monitoring.svc.cluster.local:3200`

On 2026-09-26, all running Tempo application containers reported imageID
`docker.io/grafana/tempo@sha256:0296560ac66f8a3600d7fb3014a52c189d4d9c3549ad6ff441bf2409855d68d5`.
This is an observation of the current trial deployment, not a separate imageID
record from the 2026-09-25 trace test.

The release deploys separate workloads:
- Distributor (1 replica Deployment)
- Query Frontend (1 replica Deployment)
- Querier (1 replica Deployment)
- Backend Scheduler (1 replica StatefulSet)
- Backend Worker (1 replica StatefulSet)
- Block Builder (3 replica StatefulSet, matching Kafka partition count)
- Live Store (3 replica StatefulSet, matching Kafka partition count)
- Memcached (1 replica StatefulSet, caching parquet footers, bloom filters, and search)

Kafka-backed ingest storage points to `nisshi.monitoring.svc.cluster.local:9092`,
topic `observability-tempo` (configured with 3 partitions and replication factor 1),
with `auto_create_topic_enabled: false`. Block-builder assigns 1 partition per
instance starting from pod ordinal (`partitions_per_instance: 1`):
- `tempo-block-builder-0` -> Partition 0
- `tempo-block-builder-1` -> Partition 1
- `tempo-block-builder-2` -> Partition 2
Live-store consumes from Kafka via consumer group `tempo-live-store` and serves
recent-data queries directly.

Ceph S3 storage is configured under `storage.trace.s3` pointing to bucket
`observability-tempo`, endpoint `rook-ceph-rgw-celld.rook-ceph.svc.cluster.local:80`,
`insecure: true`, and `forcepathstyle: true`. Secret `observability-tempo` provides
credentials via `global.extraEnvFrom` and
`global.extraArgs: ["-config.expand-env=true"]`.

Observed on 2026-09-25 with a dedicated Go HTTP probe client, without modifying
the existing `grafana-k8s-monitoring` release or its Grafana Cloud routes:

| Check | Result |
| --- | --- |
| Single OTLP trace push (`/v1/traces`) | HTTP 200; 131 ms latency; body `{"partialSuccess":{}}` |
| Immediate trace query (Live-Store) | HTTP 200; 32 ms latency; 1 batch returned |
| Search query (`/api/search`) | HTTP 200; 27 ms latency |
| Continuous sending across Nisshi restart | 101 traces sent; 97 HTTP 200 acknowledgements; 4 timed out during broker restart |
| Query after Nisshi restart verification | All 97 acknowledged traces returned by query frontend, 0 missing (100% retrieval) |
| Continuous sending across Live-Store restart | 139 traces sent; 139 HTTP 200 acknowledgements; 0 failures during pod deletion and re-creation |
| Query after Live-Store restart verification | All 139 acknowledged traces returned by query frontend, 0 missing (100% retrieval) |
| Continuous sending across Block-Builder restart | 93 traces sent; 93 HTTP 200 acknowledgements; 0 failures during rolling restart |
| Query after Block-Builder restart verification | All 93 acknowledged traces returned by query frontend, 0 missing (100% retrieval) |
| Live-store consumer group offsets | Partition 0: offset 40, Partition 1: offset 36, Partition 2: offset 24; lag 0 across all 3 partitions; reconnected and resumed consumption without lag upon restart |
| Block-builder partition ownership | Replicas 0, 1, and 2 actively consumed and processed their respective partitions 0, 1, and 2; re-assigned partition 0 immediately upon restart. Numeric committed offsets and lag for the block-builder consumer group were not captured. |
| Block-builder S3 upload | Flushed block `single-tenant/.../data.parquet` failed: HTTP 403 AccessDenied (`Access Denied.`) from Ceph RGW (see technical note below) |
| Release health & Cloud independence | Tempo release deployed; existing `grafana-k8s-monitoring` revision 49 Ready and untouched |

### S3 Block Shipper AccessDenied constraint

During block upload (`PUT /observability-tempo/single-tenant/<ULID>/data.parquet`),
Ceph RGW (tentacle 20.2.2) logs:
`"PUT /observability-tempo/single-tenant/.../data.parquet HTTP/1.1" 403 206 - "MinIO (linux; arm64) minio-go/v7.0.98"`
with an empty username (`-`).
Tempo, like Mimir, uses `minio-go/v7.0.98` for S3 communications. The trial
diagnosis is that, over unencrypted HTTP (`insecure: true`), a SigV4 streaming
request (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`) without
`Content-Encoding: aws-chunked` may not have been authenticated by Ceph RGW.
This mechanism was not independently confirmed. The verified result is PUT 403
`AccessDenied`; GET requests from the same Pod authenticated as
`obc-monitoring-observability-tempo-...`.

### Decision gate and fallback

In accordance with Task 5 Step 5:
- Nisshi Kafka ingestion and live-store querying **PASSED**: Spans were accepted, partitioned across Kafka, consumed by live-store with 0 lag at the recorded check, and queryable after the broker restart. Block-builder partition ownership was observed, but its numeric committed offsets and lag were not captured.
- Long-term block persistence to Ceph RGW **FAILED**: the block upload PUT returned HTTP 403 `AccessDenied`. The SigV4 streaming incompatibility is a trial diagnosis, not an established cause.
- **Production and opt-in local trace routing are kept disabled.** Enable them only after block upload succeeds, the object is confirmed in `observability-tempo`, and the stored trace is queryable after a restart.
- The existing Grafana Cloud trace export route remains active and unaffected.

Check Tempo health and consumer offsets with:

```sh
kubectl get helmreleases tempo -n monitoring
kubectl get pods -l app.kubernetes.io/instance=tempo -n monitoring
kubectl logs tempo-block-builder-0 --tail=50 -n monitoring
# In a temporary apache/kafka:4.1.0 CLI pod:
/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server nisshi.monitoring.svc.cluster.local:9092 --group tempo-live-store --describe
```

## Local Grafana trial operations

The isolated local Grafana release provides an internal, cluster-local interface to query and explore data across the three self-hosted distributed telemetry backends (`Local Loki`, `Local Mimir`, and `Local Tempo`).

### Components and dependencies

- Chart: `grafana-community/grafana` version `13.2.5` (Grafana app version `13.2.2`).
- The directly installed trial Pod used `docker.io/grafana/grafana@sha256:69a5d2d957ca0bba434c160dcd4f2d07de9d6c756a0ba10ae7f52b72ced1e4cc` (observed from its `imageID` on 2026-09-26).
- Service: internal `ClusterIP` on port 80 (forwarding to container port 3000).
- Storage: UI state is ephemeral (`persistence.enabled: false`) using an emptyDir volume.
- Configuration: Managed via Git-provisioned ConfigMaps and Flux `HelmRelease`. Initial admin credentials are chart-managed via Secret `grafana`.
- Flux sequencing: the `grafana` child depends on `monitoring-controller` and `loki` only, with health checks on its own HelmRelease and Loki's. It no longer waits on `mimir` or `tempo`, so the logs/dashboard stack can activate while those gates hold; their data sources stay provisioned but unhealthy until then.
- Authentication: use the chart-managed admin Secret `grafana`; anonymous access is disabled. Retrieve the password only when needed, without recording it in Git or shell logs.
- Data sources provisioned with stable UIDs:
  - `Local Loki` (`local-loki`): `http://loki-gateway.monitoring.svc.cluster.local` (type `loki`).
  - `Local Mimir` (`local-mimir`): `http://mimir-gateway.monitoring.svc.cluster.local/prometheus` (type `prometheus`, POST method).
  - `Local Tempo` (`local-tempo`): `http://tempo-query-frontend.monitoring.svc.cluster.local:3200` (type `tempo`).

### Verification results

Observed on 2026-09-26 with a dedicated Python test client against the Grafana REST and Explore APIs on the directly installed trial release. This trial enabled anonymous Admin access; the Git configuration disables it. API checks after reconciliation require chart-managed admin credentials.

| Check | Result |
| --- | --- |
| Datasource list (`/api/datasources`) | HTTP 200; all 3 datasources (`local-loki`, `local-mimir`, `local-tempo`) provisioned with stable UIDs |
| Loki health check | HTTP 200; `{"message": "Data source successfully connected.", "status": "OK"}` |
| Mimir health check | HTTP 200; `{"message": "Successfully queried the Prometheus API.", "status": "OK"}` |
| Tempo health check | HTTP 200; `{"message": "Data source is working", "status": "OK"}` |
| Explore query: Local Loki | HTTP 200; retrieved 10 log records matching `{job=~".+"}` from earlier trial push (e.g. `task3-... seq=179`) |
| Explore query: Local Mimir | HTTP 200; retrieved 1 metric series `task4_mimir_trial_metric_total[30m]` (timestamp 1790350227295, value 99.5) |
| Explore query: Local Tempo | HTTP 200; retrieved trace `849767fc0ff3598877001ce690137c5c` from live-store (operation `task5-trial-span`, service `tempo-trial-service`) |
| Release health & Cloud independence | Directly installed Grafana release healthy; existing `grafana-k8s-monitoring` revision 49 Ready and untouched. The Grafana Flux HelmRelease was not present at this observation. |

Check Grafana health and datasources with:

```sh
kubectl get helmreleases grafana -n monitoring
kubectl get pods -l app.kubernetes.io/name=grafana -n monitoring
kubectl port-forward svc/grafana 3000:80 -n monitoring
```

The Git-provisioned `Local Observability` dashboard includes recent Loki logs,
the Mimir trial metric, and a Tempo TraceQL search table. The dashboard uses
the three stable data source UIDs and defaults to a 48-hour range. It may show
no Mimir or Tempo data after their trial data ages out; use Explore to inspect
specific historical probes. The provider keeps the dashboard read-only in the UI.
The dashboard has been rendered from Git but has not been deployed or checked
in the live UI in this task.

A read-only follow-up on 2026-09-26 used the existing direct release through a
local port forward. All three provisioned source UIDs and URLs matched the Git
configuration, and all three source health endpoints returned HTTP 200 with
`status: OK`. A Loki range query returned 10 trial lines, including `seq=179`;
a Mimir range-vector query returned the trial metric at timestamp
`1790350227.295` with value `99.5`. The known Tempo trace returned HTTP 404
and a search for `tempo-trial-service` returned zero traces. The earlier trace
result was observed during the live-store trial, but this follow-up cannot
establish its continued availability while Tempo block uploads remain blocked.
No live Grafana configuration or telemetry route was changed in this follow-up.

## Opt-in local Alloy log collection

`components/observability-local-alloy/` defines a separate Alloy Deployment,
generated ConfigMap, Service, and ServiceAccount. Kustomize hashes the
`config.alloy` content into the ConfigMap name and rewrites the Deployment's
ConfigMap volume reference; a configuration edit therefore changes the Pod
template when the child Kustomization reconciles. Its image is pinned to the
immutable digest observed on the existing Cloud receiver Pod on 2026-09-26:
`docker.io/grafana/alloy@sha256:b8ec653c44235fbe910879145dac3597d66b0aaecf60bcbbe82580767771a839`.
The Flux controller is `clusters/home/controllers/observability-local-alloy.yaml`
and depends on Loki. Its Service is ClusterIP at
`observability-local-alloy.monitoring.svc.cluster.local:12345` for Alloy health
and diagnostics; it does not accept OTLP.

Only Pods with the exact label
`observability.nakatanakatana.app/local: "true"` are eligible for local log
collection. The Kubernetes discovery selector and an Alloy relabel keep rule
both enforce the value. The source reads those containers through the
Kubernetes Pod log API and sends them to
`http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push`. Every
record carries the stable label `job="observability-local-alloy"`, set by an
explicit relabel rule; the `Local Observability` dashboard queries that exact
value with equality. This configuration uses a cluster-wide
`ClusterRole`/`ClusterRoleBinding` (it can list Pods and read Pod logs in all
namespaces) because discovery scans all namespaces; Kubernetes RBAC can also
be scoped with Roles when the design only needs selected namespaces. Actual
collection stays opt-in via the label selector and keep rule. Log batches are capped at 512 KiB
(`batch_size`), at most 1000 streams (`max_streams`), retries are capped at
five with a 30-second maximum backoff, and the Deployment has a 512 MiB
memory limit. No per-endpoint queue size is set in the committed Alloy config,
so no queue-capacity figure is claimed here. Positions live on a 256 MiB
`emptyDir`; after an Alloy restart or reschedule, already-sent lines can be
reread and duplicated in Loki. During a prolonged Loki or Nisshi outage,
local logs can be lost when this bounded buffer and retry budget are
exhausted; this must be measured in a later isolated trial.

Local metric discovery, the 15-second scrape, remote write to Mimir, the
local OTLP receiver, and trace export to Tempo are disabled. Mimir has not
passed its block-upload and near-16 MiB Kafka record gates, and Tempo has not
passed its S3 block-persistence gate. No local metric or trace canary should
be sent until those gates pass. The existing Cloud Alloy release and its
metric, log, and trace destinations are unchanged.

Before enabling this Flux controller, complete an isolated log canary trial:
verify that a labeled Pod's unique log line appears in Local Loki, that an
otherwise identical unlabeled Pod's line is absent, and that the Cloud path
remains healthy. Also verify that the returned Loki stream has the exact
`job="observability-local-alloy"` label used by the dashboard query. Then
measure queue growth, loss and recovery during an isolated local Loki/Nisshi
stop or outage trial, and confirm Cloud telemetry continues and the Cloud
Alloy HelmRelease stays Ready. Stop and outage tests are deferred; do not run
them until that hold is lifted. The original all-signal canary and Nisshi
outage acceptance tests remain pending. This task committed manifests only;
it did not apply or reconcile the controller, deploy a canary, or cause an
outage.

## Deployment acceptance and recovery record (2026-09-26)

Task 8 ran static checks and read-only cluster checks. The user deferred all
stop and outage tests. No manifest was applied or reconciled, no Pod was
restarted, and no telemetry was sent in this verification round.

| Gate | Evidence and present status |
| --- | --- |
| Repository tests | `go test ./...` passed (`github.com/nakatanakatana/x/tests`, 5.487 s). |
| Component renders | `kustomize build` passed for Nisshi, Loki, Mimir, Tempo, Grafana, and local Alloy. `helm template` passed for the four pinned charts in this runbook. |
| Repository ownership | `go run ./tests repository --repo-root .` did not finish. Outside the sandbox it stopped while rendering the existing Cloudflare remote base with `fs-security-constraint`; therefore it did not establish unique ownership for every repository resource. |
| Ceph claims | All seven ObjectBucketClaims were `Bound`; `CephObjectStore/celld` was `Ready`. The `celld-rgw` StorageClass had reclaim policy `Retain`. This is a point-in-time control-plane check, not a fresh object read. |
| Nisshi and Loki | Nisshi and Loki Pods were Running. `HelmRelease/loki` was Ready at revision 2, chart `loki@18.13.5`. The earlier acknowledged-log and Loki S3 chunk/index trial passed; no new restart or query was performed here. |
| Mimir and Tempo | Their trial Pods were Running, but their HelmReleases were absent from the current `monitoring` namespace. Earlier Ceph block PUTs returned 403 for both. Mimir's proposed SigV2 settings have not been applied; near-limit record acceptance remains unproved. Metric and trace routing remain disabled. |
| Grafana and local Alloy | The direct Grafana trial Pod was Running, but its HelmRelease was absent. The Git-managed dashboard and authentication settings have not been checked after Flux reconciliation. No local Alloy Pod or HelmRelease was present; opt-in log canaries remain unverified. |
| Grafana Cloud | `HelmRelease/grafana-k8s-monitoring` was Ready at revision 49, chart `k8s-monitoring@4.5.2`. `git diff dc3e068 -- components/monitoring/values.yaml clusters/home/configs/external-secrets/grafana-cloud-secret.yaml` was empty. This proves the committed Cloud destination URLs and Secret mapping are unchanged; delivery during a local outage was not tested. |
| Recovery and isolation | New write/read-path restarts, known-data re-queries, all-signal canaries, Nisshi interruption, and bounded RGW denial are pending under the user's stop/outage hold. Recovery time, query gap, local buffering loss, and Cloud independence during those failures remain unmeasured. |

The current application image observations are Nisshi
`ghcr.io/nisshi-io/nisshi@sha256:f062b76a500f4629e5faad5bd106aafa6705a83bea9c7a21eefe70b55b663250`
and Loki ingester
`docker.io/grafana/loki@sha256:1107dd5274e0ada47e42472b7a7e71f3b2a2fe878878108f3e2f9e51528f0193`.
The chart pins are Loki `18.13.5`, Mimir `6.2.0`, Tempo `3.7.0`, and
Grafana `13.2.5`; the Mimir, Tempo, and Grafana imageIDs above are earlier
2026-09-26 trial observations, not historical imageIDs for every test.
The local Alloy digest above is a Git pin from the Cloud receiver observation;
the local Alloy Deployment has not run.

No explicit production retention period or bucket lifecycle policy is set in
these component values. The pinned Tempo 3.7.0 chart render includes defaults
`block_retention: 48h` and `compacted_block_retention: 1h`; these are chart
defaults, not user overrides or an approved production retention policy.
Loki's `reject_old_samples_max_age: 168h` rejects old ingest samples; it is
not a data-retention policy. The seven bucket claims use `Retain`, so deleting
a claim is not a data-purge procedure. Alert rules,
rule evaluation, silence/Alertmanager recovery, backup inventory, and restore
from a Ceph backup have not been verified.

Resource requests are provisional: Nisshi requests 100m CPU/128Mi and limits
CPU to 1 core and memory to 1Gi; Mimir application components generally
request 50m/128Mi (gateway 20m/32Mi, overrides exporter 20m/64Mi) and its
four stateful roles each request a 10Gi PVC. Tempo roles request 50m/128Mi;
Grafana requests 50m/128Mi; local Alloy requests 50m/128Mi and has a 256Mi
`emptyDir.sizeLimit` for `/var/lib/alloy`. Loki ingester and compactor each
have a 10Gi PVC;
the chart supplies their other resource defaults. No sustained-load CPU,
memory, disk, RGW request-rate, or retention-capacity measurements justify
production sizing yet.

Durable PVCs pin `storageClass: rook-ceph-block`: Loki sets it per
`ingester.persistence.claims[0]` and `compactor.persistence.claims[0]` (the
chart schema keeps the class on each claim entry; there is no effective
top-level persistence class key), plus Mimir
`alertmanager`/`compactor`/`ingester`/`store_gateway`
`persistentVolume.storageClass`. Tempo's `storage.trace.s3` now sets
`region: us-east-1` explicitly alongside the Ceph endpoint, path-style access,
and secret-sourced credentials. Confirm both render in the pinned-chart
template output before unsuspending (see gates below).

### Controller activation and validation gates

Before source reconciliation, confirm all seven ObjectBucketClaims are
`Bound` and each matching generated Secret and ConfigMap exists in
`monitoring`; check names and status only, never Secret values. This was
confirmed on 2026-09-26 and must be rechecked before applying the source.

- Confirm all seven ObjectBucketClaims are `Bound` and each matching generated
  Secret and ConfigMap exists in `monitoring`; check names and status only,
  never Secret values. Do not unsuspend a backend whose bucket or credentials
  are not ready.
- Confirm the pinned Nisshi image starts as a non-root user. If image metadata
  does not establish a numeric non-root UID, inspect the first Flux-managed
  Pod's startup result and keep dependent Kustomizations blocked until its
  supported UID and writable paths are verified.
  The first Flux-managed Pod was rejected because the pinned image defaults to
  root. The validation manifest now sets UID/GID `65532`; verify the broker
  reaches Ready and its S3-backed startup succeeds before dependent children
  proceed.
- Render the pinned charts from local cache only (`helm template` with the
  versions in this runbook, plus `kustomize build` per component) and confirm
  `storageClassName: rook-ceph-block` on the Loki ingester/compactor and
  Mimir stateful PVCs, `region: us-east-1` in the Tempo S3 config, and the
  `job="observability-local-alloy"` relabel in the Alloy ConfigMap.
- Confirm the rendered Loki containers retain
  `-config.expand-env=true`; its S3 credentials are referenced by environment
  variables in structured configuration and require Loki environment expansion.
- `HelmRelease/loki` exists from the manual trial. Flux will reconcile it to
  committed values; inspect its non-secret settings and history during
  activation. Do not delete retained ObjectBucketClaims, Secrets, ConfigMaps,
  or PVCs when replacing test workloads.
- The retained Loki and Mimir PVCs were `Bound` to `local-path` on
  2026-09-26, while the chart values request `rook-ceph-block`. PVC storage
  classes are immutable; record the actual class after activation and do not
  claim Ceph-backed PVC validation unless new claims are provisioned on
  `rook-ceph-block`. Preserve existing claims and their data.
- Inspect the rendered manifests for chart-wide S3 env injection: Loki
  `defaults.extraEnvFrom`, Mimir `global.extraEnv`, and Tempo
  `global.extraEnvFrom` may expose bucket credentials beyond the pods that
  need each Secret; confirm the actual scope in the pinned-chart render
  before unsuspending. Narrow the injection to the components that need
  each Secret only when render evidence shows a chart-supported
  per-component path; otherwise keep this as a known-broad permission.
- This validation activation proceeds with the Mimir / Tempo block-persistence
  gates open so their product write paths can be observed. Keep metric and
  trace routes disabled until S3 block upload, object existence, and
  post-restart query checks pass. The Mimir near-limit Kafka record gate and
  all stop/outage tests remain open and are not part of this activation.

### Read-only triage and restore sequence

Run these first to identify the failed layer without exposing Secret values:

```sh
kubectl get cephobjectstore celld -n rook-ceph
kubectl get objectbucketclaims -o custom-columns=NAME:.metadata.name,PHASE:.status.phase -n monitoring
kubectl get pvc -n monitoring
kubectl get helmreleases -n monitoring
kubectl get deployment,service nisshi -n monitoring
kubectl get pods -n monitoring
kubectl get kustomizations -n flux-system
```

Restore the original objects and credentials from an independently verified
Ceph/Secret backup before restarting a backend. A newly `Bound` claim alone
does not restore old Loki chunks, Mimir blocks, Tempo blocks, or Nisshi topic
objects. Record the restored bucket names, object counts/keys, Secret key
names, and Nisshi topic offsets; the backup source and exact Ceph import
command remain site-specific and are not yet documented or tested.

After data is restored, authorize each backend separately. For each authorized
child, change its controller file's `spec.suspend` to `false` in Git and publish
that change to the Flux `GitRepository/flux-system` source. Reconcile the source
and parent `cluster-controllers` Kustomization, then verify the child's live
`spec.suspend` is `false` before reconciling it. A direct `flux reconcile`
cannot make a Git-suspended child active. Child dependencies stage startup:
Nisshi first; Loki, Mimir, and Tempo after Nisshi and `monitoring-controller`;
Grafana and local Alloy after Loki. Keep metric and trace routes disabled while
the Mimir and Tempo block-persistence gates remain open. `grafana` now depends only on
`monitoring-controller` and `loki`, with health checks on its own HelmRelease
and Loki's, so the approved logs/dashboard stack (Loki, Grafana, local Alloy)
can proceed once Loki is authorized while `mimir` and `tempo` stay held. The
provisioned Mimir and Tempo data sources will fail health checks until those
backends are authorized and Ready; that is expected while their gates hold.
Enable the local
Alloy child only after Loki is ready and an opt-in log canary is authorized.

These are the ordered commands for an authorized recovery after the matching
Git changes have reached the source:

```sh
flux reconcile kustomization cluster-configs --with-source -n flux-system
flux reconcile kustomization monitoring-controller --with-source -n flux-system
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization cluster-controllers --with-source -n flux-system
kubectl get kustomizations nisshi loki mimir tempo grafana observability-local-alloy -n flux-system \
  -o custom-columns=NAME:.metadata.name,SUSPEND:.spec.suspend
# Run each child command only after its Git suspension is lifted and verified:
flux reconcile kustomization nisshi --with-source -n flux-system
flux reconcile kustomization loki --with-source -n flux-system
# Once Nisshi is Ready, reconcile Mimir and Tempo for bounded write validation.
# Keep metric and trace routes disabled while persistence checks are open.
flux reconcile kustomization mimir --with-source -n flux-system
flux reconcile kustomization tempo --with-source -n flux-system
# Grafana and local Alloy follow Loki according to their dependencies.
flux reconcile kustomization grafana --with-source -n flux-system
flux reconcile kustomization observability-local-alloy --with-source -n flux-system
```

On 2026-09-26 those component Kustomizations were absent from `flux-system`,
so these commands were not run and are not yet a proven restore path. After an
authorized recovery, recheck each backend's known pre-failure data, bucket
objects, topic offsets, and local/Cloud destinations before enabling any new
route. Keep metric and trace routes disabled until their product-specific
Ceph persistence and post-restart query gates pass.
