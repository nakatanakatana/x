# Object Storage Backup Operations Runbook

`CronJob/app/object-storage-backup` copies the configured object stores to the
pCloud S3 gateway once per hour. It is an object-level mirror, not a database
backup or a pCloud API durability proof. Use this runbook from an approved
operations environment. Do not print, manually decode, paste, or commit
credential values. The controlled-failure procedure below loads credentials
through the approved Secret delivery mechanism without printing them.

## Storage mapping and credentials

The job reads only these sources. Every source remote uses `provider=Other`,
`region=us-east-1`, and path-style addressing.

| Source | Endpoint | Bucket | Secret key mapping | Destination prefix |
| --- | --- | --- | --- | --- |
| Ceph RGW | `http://rook-ceph-rgw-celld.rook-ceph.svc.cluster.local:80` | `celld` | `Secret/app/celld-storage`: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `s3-backups/celld/` |
| S3-compatible storage | `http://storage-clusterip.tailscale.svc.cluster.local:8010` | `feed-reader` | `Secret/app/feed-reader-storage`: `access_key`, `access_secret` | `s3-backups/feed-reader/` |
| S3-compatible storage | `http://storage-clusterip.tailscale.svc.cluster.local:8010` | `nostr` | `Secret/app/nostr-storage`: `access-key-id`, `secret-access-key` | `s3-backups/nostr/` |

The destination is bucket `s3-backups` at
`http://gateway.pcloud-s3.svc.cluster.local:8080`, also with `provider=Other`,
`region=us-east-1`, and path-style addressing. `ExternalSecret/app/object-storage-backup-credentials`
reads `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` from the `pcloud-s3` item
in the `k8s` 1Password vault. The item contains `PCLOUD_TOKEN`,
`S3_ACCESS_KEY_ID`, and `S3_SECRET_ACCESS_KEY`. `RCLONE_AUTH_KEY` is generated
by `ExternalSecret/pcloud-s3/rclone-s3-credentials` from the S3 keys for the
gateway; the backup does not receive `PCLOUD_TOKEN` or `RCLONE_AUTH_KEY`.

`ExternalSecret/app/object-storage-backup-credentials` and
`ExternalSecret/pcloud-s3/rclone-s3-credentials` intentionally read the same
two S3 fields. A Pod in `app` cannot mount a Secret from `pcloud-s3`, so the
second ExternalSecret creates an `app`-namespace Secret for the CronJob. Check
only readiness and key names when reconciling the credentials:

The backup Job currently reuses the existing source storage credentials and the
pCloud S3 gateway credential. The source credentials may have read/write
capability because they are also used by the applications, and the gateway
credential can access the gateway's configured root. Before enabling the
schedule, provision source read-only credentials and a backup-scoped pCloud
gateway credential if this broader access is not acceptable; creating those
external credentials is outside this repository.

```bash
kubectl -n app get externalsecret object-storage-backup-credentials
kubectl -n app get secret object-storage-backup-credentials \
  -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}' | sort
```

## Safe first run

`Kustomization` `cluster-resources` in namespace `flux-system` reconciles
`clusters/home/resources` every ten minutes, so pause it before changing the
CronJob. The following keeps Flux reconciliation and the CronJob suspended on
every failure, including a failed manual Job. It uses a unique Job name, waits
for completion, and prints only the Job logs. It does not retrieve Secret
values.
`cluster-resources` is paused for CronJob and ConfigMap mutations;
`cluster-configs` remains active unless ExternalSecrets are being changed.

Pausing `cluster-resources` also delays unrelated resources under
`clusters/home/resources`. Keep the validation window short, do not make
unrelated changes during it, and restore normal reconciliation only through the
Git-managed procedure below.

```bash
set -euo pipefail

restore_dry_run_and_keep_suspended() {
  status=$?
  kubectl -n app set env cronjob/object-storage-backup \
    OBJECT_STORAGE_BACKUP_DRY_RUN=false || true
  kubectl -n app patch cronjob object-storage-backup \
    --type merge -p '{"spec":{"suspend":true}}' || true
  exit "$status"
}

wait_for_job() {
  job="$1"
  expected="$2"
  deadline=$(( $(date +%s) + 3600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    complete=$(kubectl -n app get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' || true)
    failed=$(kubectl -n app get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)
    if [ "$expected" = complete ] && [ "$complete" = True ]; then
      return 0
    fi
    if [ "$expected" = failed ] && [ "$failed" = True ]; then
      return 0
    fi
    if [ "$expected" = complete ] && [ "$failed" = True ]; then
      return 1
    fi
    if [ "$expected" = failed ] && [ "$complete" = True ]; then
      return 1
    fi
    sleep 10
  done
  echo "timed out waiting for Job $job" >&2
  return 124
}

trap restore_dry_run_and_keep_suspended EXIT
flux suspend kustomization cluster-resources -n flux-system

kubectl -n app patch cronjob object-storage-backup \
  --type merge -p '{"spec":{"suspend":true}}'

restore_dry_run() {
  kubectl -n app set env cronjob/object-storage-backup \
    OBJECT_STORAGE_BACKUP_DRY_RUN=false
}

kubectl -n app set env cronjob/object-storage-backup \
  OBJECT_STORAGE_BACKUP_DRY_RUN=true

backup_job="object-storage-backup-dry-run-$(date +%s)-$$"
kubectl -n app create job --from=cronjob/object-storage-backup "$backup_job"
if ! wait_for_job "$backup_job" complete; then
  kubectl -n app logs "job/$backup_job" --all-containers=true || true
  exit 1
fi
kubectl -n app logs "job/$backup_job"

restore_dry_run
test "$(kubectl -n app get cronjob object-storage-backup \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="OBJECT_STORAGE_BACKUP_DRY_RUN")].value}')" = false
trap - EXIT
printf '%s\n' 'Dry run succeeded. After the dry run, leave Flux and the CronJob suspended. Continue with Validation and recovery before enabling the schedule.'
```

If the manual Job fails, leave the CronJob suspended. Inspect the Job and its
Pod, and verify that the cleanup restored the CronJob's dry-run setting before
making any Git change to enable the schedule:

```bash
kubectl -n app describe job "$backup_job"
kubectl -n app get pods -l job-name="$backup_job"
kubectl -n app logs "job/$backup_job" --all-containers=true
kubectl -n pcloud-s3 logs deployment/rclone-s3-gateway --since=1h
kubectl -n app get cronjob object-storage-backup \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="OBJECT_STORAGE_BACKUP_DRY_RUN")].value}{"\n"}'
```

The `EXIT` cleanup restores `OBJECT_STORAGE_BACKUP_DRY_RUN=false` and patches
the CronJob back to `suspend: true` when the manual Job fails, when
`wait_for_job` fails or times out, and when another command exits the
procedure early.
It never resumes `Kustomization` `cluster-resources`; that Kustomization and
the CronJob therefore remain suspended until validation is complete. To enable
the schedule after all validation passes, change `spec.suspend` to `false` in
`clusters/home/resources/object-storage-backup.yaml`, commit and push that Git
change, and then resume `Kustomization` `cluster-resources` in `flux-system`.
The committed backup manifest and its test intentionally keep `spec.suspend` set
to `true`; the enablement change must update `TestObjectStorageBackup`'s expected
suspend value in the same change so CI continues to verify the Git-managed state.
Do not use a live `kubectl patch` to enable the schedule because Flux will
restore the Git-managed value.

The script captures each source listing before `sync` and uses that same listing
for the source file set and the post-sync check. An empty or failed source
listing skips only that source; other sources continue. Do not treat an
intentionally empty source as a normal first run: obtain an approved manifest
change before allowing that source to be empty. Each sync uses
`--delete-after`, `--delete-excluded`, `--max-delete 1000`, and
`--max-delete-size 10GiB`. Reaching either deletion limit fails the Job rather
than allowing an unbounded deletion. The deletion limit does not roll back
earlier deletions in the same invocation, so a limit failure can leave a
destination prefix partially reconciled. A transfer failure or a failure in a
later source can leave partial state: a failed Job does not roll back successful
synchronization of earlier sources. The Job has no automatic retry; inspect
each destination prefix before starting another run.
Each source listing is written to `/tmp`, backed by the `emptyDir` and container
ephemeral-storage limit of 1Gi. Estimate the combined listing size during the
dry run before enabling the schedule; increase both limits together if the
source object count could approach that capacity.
The script logs each source listing as
`source=<remote> listing_objects=<count> listing_bytes=<bytes>`; record all three
values from the dry-run Job logs and compare them with the expected source object
counts before enabling the schedule. If a later dry-run listing drops
unexpectedly from the recorded baseline, keep the schedule suspended and
investigate the source listing before enabling it.

After a successful dry run, run a manual non-dry-run Job while Flux and the
CronJob remain suspended. The runtime `OBJECT_STORAGE_BACKUP_DRY_RUN` setting
in the manifest is `false`; use the following command before the readback and
deletion checks below:

```bash
set -euo pipefail

wait_for_job() {
  job="$1"
  expected="$2"
  deadline=$(( $(date +%s) + 3600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    complete=$(kubectl -n app get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' || true)
    failed=$(kubectl -n app get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)
    if [ "$expected" = complete ] && [ "$complete" = True ]; then
      return 0
    fi
    if [ "$expected" = failed ] && [ "$failed" = True ]; then
      return 0
    fi
    if [ "$expected" = complete ] && [ "$failed" = True ]; then
      return 1
    fi
    if [ "$expected" = failed ] && [ "$complete" = True ]; then
      return 1
    fi
    sleep 10
  done
  echo "timed out waiting for Job $job" >&2
  return 124
}

validation_job="object-storage-backup-validation-$(date +%s)-$$"
kubectl -n app create job --from=cronjob/object-storage-backup "$validation_job"
if ! wait_for_job "$validation_job" complete; then
  kubectl -n app logs "job/$validation_job" --all-containers=true || true
  exit 1
fi
kubectl -n app logs "job/$validation_job" --all-containers=true
```

## Validation and recovery

Perform validation with an approved, credentialed in-cluster S3 client. Keep
credentials in its approved Secret delivery mechanism rather than in shell
history or this runbook.

Do not enable the schedule until a real non-dry-run gateway validation has
passed. Repository tests and dry-run Jobs do not prove that the configured
pCloud S3 gateway can write, read back, check, and delete an object. Perform
the following validation against the actual in-cluster gateway and leave the
CronJob suspended if any step fails.

1. Upload a uniquely named temporary object to one source, for example under
   `backup-validation/<timestamp>` in `celld`. Run a manual non-dry-run Job,
   wait for completion, then read the object through
   `http://gateway.pcloud-s3.svc.cluster.local:8080` from
   `s3-backups/celld/backup-validation/<timestamp>`. Compare the readback with
   the uploaded content.
2. Wait for the Job's built-in 10-second gateway write-back window and confirm
   the Job log contains its `rclone check`. Read the same destination object
   again through the pCloud S3 gateway. Inspect gateway logs if the readback or
   check fails; `rclone check` does not prove direct pCloud API durability.
   The Job intentionally runs `rclone check` with the source listing captured
   before `sync`, `--files-from-raw`, and `--one-way`: it verifies every listed
   source object. `rclone check` verifies checksums when the remote exposes
   them; otherwise it may fall back to size comparison. It does not report
   destination-only objects.
   Validate deletion of a known object in the next step and inspect the complete
   destination prefix when investigating unexpected leftovers.
3. Delete that temporary source object in a controlled operation. Run another
   manual non-dry-run Job and verify that the active destination object no
   longer appears under its destination prefix after the 10-second window.
4. Restore by reading or copying the required object from the corresponding
   destination prefix (`s3-backups/celld/`, `s3-backups/feed-reader/`, or
   `s3-backups/nostr/`) through the pCloud S3 gateway into a separate recovery
   location. Read the recovered object and compare its checksum or contents
   before returning it to a source.

### Controlled failure validation

Run this validation only after a successful normal copy. Run the entire
controlled failure validation block from one approved in-cluster operations
shell. Do not split the block across shells: its local variables and temporary
files are part of the before/after comparison. The shell must have a
credentialed `pcloud` rclone remote without exposing credentials. That remote
must use the same in-cluster S3 gateway as the CronJob:
`http://gateway.pcloud-s3.svc.cluster.local:8080`, with path-style addressing
and the S3 access keys from the approved Secret. Do not use a native pCloud
API remote for this comparison.
Configure the remote's non-secret settings and load its access keys through the
approved Secret delivery mechanism before running the comparison. Do not print
the exported environment or put decoded key values in shell history:

```bash
export RCLONE_CONFIG_PCLOUD_TYPE=s3
export RCLONE_CONFIG_PCLOUD_PROVIDER=Other
export RCLONE_CONFIG_PCLOUD_ENDPOINT=http://gateway.pcloud-s3.svc.cluster.local:8080
export RCLONE_CONFIG_PCLOUD_REGION=us-east-1
export RCLONE_CONFIG_PCLOUD_FORCE_PATH_STYLE=true
export RCLONE_CONFIG_PCLOUD_UPLOAD_CUTOFF=5GiB
export RCLONE_CONFIG_PCLOUD_ACCESS_KEY_ID="$(
  kubectl -n app get secret object-storage-backup-credentials \
    -o jsonpath='{.data.S3_ACCESS_KEY_ID}' | base64 --decode
)"
export RCLONE_CONFIG_PCLOUD_SECRET_ACCESS_KEY="$(
  kubectl -n app get secret object-storage-backup-credentials \
    -o jsonpath='{.data.S3_SECRET_ACCESS_KEY}' | base64 --decode
)"
```

Then deliberately make the `celld` source listing fail by pointing only the
manual Job at an unreachable loopback endpoint. This preserves the exact
configured endpoint in the restore function. As with the dry run, the trap
restores the temporary setting and keeps both Flux reconciliation and the
CronJob suspended on every unsuccessful command.

Replace `<known-existing-key>` with an existing object key before running this
block.

```bash
set -euo pipefail

validation_object='s3-backups/celld/<known-existing-key>'
rclone cat "pcloud:${validation_object}" > /tmp/object-storage-backup-before
sha256sum /tmp/object-storage-backup-before

wait_for_job() {
  job="$1"
  expected="$2"
  deadline=$(( $(date +%s) + 3600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    complete=$(kubectl -n app get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' || true)
    failed=$(kubectl -n app get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)
    if [ "$expected" = complete ] && [ "$complete" = True ]; then
      return 0
    fi
    if [ "$expected" = failed ] && [ "$failed" = True ]; then
      return 0
    fi
    if [ "$expected" = complete ] && [ "$failed" = True ]; then
      return 1
    fi
    if [ "$expected" = failed ] && [ "$complete" = True ]; then
      return 1
    fi
    sleep 10
  done
  echo "timed out waiting for Job $job" >&2
  return 124
}

restore_failure_validation() {
  status=$?
  kubectl -n app set env cronjob/object-storage-backup \
    RCLONE_CONFIG_CELLD_ENDPOINT=http://rook-ceph-rgw-celld.rook-ceph.svc.cluster.local:80 \
    OBJECT_STORAGE_BACKUP_DRY_RUN=false || true
  kubectl -n app patch cronjob object-storage-backup \
    --type merge -p '{"spec":{"suspend":true}}' || true
  exit "$status"
}

trap restore_failure_validation EXIT
flux suspend kustomization cluster-resources -n flux-system
kubectl -n app patch cronjob object-storage-backup \
  --type merge -p '{"spec":{"suspend":true}}'
kubectl -n app set env cronjob/object-storage-backup \
  RCLONE_CONFIG_CELLD_ENDPOINT=http://127.0.0.1:1 \
  OBJECT_STORAGE_BACKUP_DRY_RUN=true
test "$(kubectl -n app get cronjob object-storage-backup \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="OBJECT_STORAGE_BACKUP_DRY_RUN")].value}')" = true

failure_job="object-storage-backup-source-failure-$(date +%s)-$$"
kubectl -n app create job --from=cronjob/object-storage-backup "$failure_job"
if ! wait_for_job "$failure_job" failed; then
  kubectl -n app logs "job/$failure_job" --all-containers=true || true
  exit 1
fi
kubectl -n app logs "job/$failure_job" --all-containers=true

rclone cat "pcloud:${validation_object}" > /tmp/object-storage-backup-after
cmp /tmp/object-storage-backup-before /tmp/object-storage-backup-after
sha256sum /tmp/object-storage-backup-after

kubectl -n app set env cronjob/object-storage-backup \
  RCLONE_CONFIG_CELLD_ENDPOINT=http://rook-ceph-rgw-celld.rook-ceph.svc.cluster.local:80 \
  OBJECT_STORAGE_BACKUP_DRY_RUN=false
test "$(kubectl -n app get cronjob object-storage-backup \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="RCLONE_CONFIG_CELLD_ENDPOINT")].value}')" = http://rook-ceph-rgw-celld.rook-ceph.svc.cluster.local:80
test "$(kubectl -n app get cronjob object-storage-backup \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="OBJECT_STORAGE_BACKUP_DRY_RUN")].value}')" = false
trap - EXIT
printf '%s\n' 'The manual Job failed as expected and the existing destination object is unchanged. Keep Flux and the CronJob suspended; enable the schedule only through a Git change after validation.'
```

If the operations shell is killed before its `EXIT` trap runs, do not resume
Flux. Read back `OBJECT_STORAGE_BACKUP_DRY_RUN`,
`RCLONE_CONFIG_CELLD_ENDPOINT`, and `spec.suspend`, then restore the original
endpoint, set dry-run to `false`, and keep the CronJob suspended before
continuing validation.

This dry-run controlled failure validates only that a failed source listing stops
that source before `sync`; it does not exercise a non-dry-run transfer. Keeping
the failure validation dry-run prevents the other sources, which continue after
the failed source, from changing their destinations during the test.

The manual Job must reach the `Failed` condition; an active Job or a completed
Job is not evidence of the required failure handling. The `cmp` and checksum
must show that the existing destination object stayed readable and unchanged.
Manual validation Jobs must use the documented prefixes because the failed-Job
expression excludes those prefixes. Scheduled Jobs created by the CronJob do
not use these manual-validation prefixes.
Do not test this with an empty destination prefix, and do not purge pCloud
Trash while validating the failure.

The active destination mirror removes objects deleted from a source. pCloud
Trash is not emptied by this procedure or by the CronJob; it remains available
subject to the pCloud account's retention policy. Do not add a Trash-purge
operation while investigating or recovering data.

`RCLONE_CONFIG_PCLOUD_UPLOAD_CUTOFF=5GiB` is the multipart threshold, not a
maximum object-size guard. Objects up to 5 GiB use single-request uploads;
larger objects use multipart uploads and require separately validated gateway
memory capacity. The backup does not reject objects larger than 5 GiB.

## Failure monitoring

Check the CronJob's last schedule and success time, then inspect recent Jobs:

```bash
kubectl -n app get cronjob object-storage-backup \
  -o jsonpath='{.status.lastScheduleTime}{" last successful: "}{.status.lastSuccessfulTime}{"\n"}'
kubectl -n app get jobs --sort-by=.status.startTime
kubectl -n app get jobs -l app.kubernetes.io/name=object-storage-backup
```

These are reference expressions only; this repository does not install these
alerts. Because the CronJob is intentionally suspended during validation, gate
the never-success, scheduler-stall, and stale-success alerts on
`spec.suspend == false`. The `kube_cronjob_spec_suspend`,
`kube_cronjob_status_last_schedule_time`, and
`kube_cronjob_status_last_successful_time` metrics must be available in the
kube-state-metrics allowlist.

Never-success alert condition (apply `for: 3h` in the alert rule):

```promql
kube_cronjob_spec_suspend{namespace="app", cronjob="object-storage-backup"} == 0
unless on (namespace, cronjob)
kube_cronjob_status_last_successful_time{namespace="app", cronjob="object-storage-backup"}
```

The condition above intentionally uses the alert rule's `for: 3h` rather than
subtracting the last schedule time. A scheduled Job can fail while
`kube_cronjob_status_last_schedule_time` is refreshed every hour.

The separate scheduler-stall condition uses the last schedule time:

```promql
kube_cronjob_spec_suspend{namespace="app", cronjob="object-storage-backup"} == 0
and on (namespace, cronjob)
(time() - kube_cronjob_status_last_schedule_time{namespace="app", cronjob="object-storage-backup"} > 3 * 60 * 60)
```

Retain the separate stale-success alert for an enabled CronJob that succeeded
before but has not succeeded within three hours:

```promql
kube_cronjob_spec_suspend{namespace="app", cronjob="object-storage-backup"} == 0
and on (namespace, cronjob)
time() - kube_cronjob_status_last_successful_time{namespace="app", cronjob="object-storage-backup"} > 3 * 60 * 60
```

Check failed Jobs with:

```promql
(
  kube_job_status_failed{
    namespace="app",
    job_name=~"object-storage-backup-.*",
    job_name!~"object-storage-backup-(source-failure|dry-run|validation)-.*"
  } > 0
  and on (namespace, job_name)
  (time() - kube_job_status_start_time{namespace="app", job_name=~"object-storage-backup-.*"} < 3 * 60 * 60)
)
unless on (namespace, job_name)
kube_job_status_succeeded{namespace="app", job_name=~"object-storage-backup-.*"} > 0
```

Inspect the matching Job logs. `kube_job_status_start_time` limits this query to
recent failures and identifies the affected run. `concurrencyPolicy: Forbid`
skips a scheduled run when a previous Job is still active; it does not run the
two Jobs concurrently. Therefore, investigate a long-running active Job as well
as failed Jobs. Enable the three-hour never-success, scheduler-stall, and
stale-success alerts only after the CronJob is enabled in Git.
`activeDeadlineSeconds: 3300` bounds the duration for which one Job can
suppress later schedules. The `app.kubernetes.io/name=object-storage-backup`
label is set deliberately on the CronJob Job template, so it selects both
scheduled Jobs and manually created Jobs from this exact CronJob.
