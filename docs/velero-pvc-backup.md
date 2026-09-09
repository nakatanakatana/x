# Velero PVC バックアップ & リストア運用手順書

本ドキュメントでは、Kubernetes クラスタ内の PersistentVolumeClaim (PVC) を pCloud S3 ゲートウェイへバックアップし、新規 PVC へ安全にリストアするための運用手順を説明します。

---

## 1. アーキテクチャと初回ロールアウト方針

### 1.1 アーキテクチャ概要

- **ツール選定**: Velero (`v1.18.1` / Helm Chart `12.1.0`) + CSI Snapshot Data Movement
- **スナップショット方式**: Rook Ceph RBD の CSI ボリュームスナップショット (`VolumeSnapshotClass`: `rook-ceph-block-snapshot`, driver: `rook-ceph.rbd.csi.ceph.com`)
- **データ転送・暗号化**: Velero node-agent によるスナップショットデータの移動 (`snapshotMoveData: true`)。暗号化は Kopia リポジトリ暗号化 (`VELERO_REPOSITORY_PASSWORD`) を使用。
- **バックアップストレージ**:
  - `BackupStorageLocation`: `pcloud` (バケット: `velero-backups`)
  - エンドポイント: `http://gateway.pcloud-s3.svc.cluster.local:8080` (namespace `pcloud-s3` 内の Service `gateway`)
  - パススタイルアクセス (`s3ForcePathStyle: "true"`)、チェックサム計算無効 (`checksumAlgorithm: ""`)
- **vCluster PVC 同期**: `vcluster-app` の仮想 PVC をホストクラスタの PVC として同期し、ホストクラスタにインストールした Velero でバックアップします。
- **スケジュール**:
  - `Schedule`: `pvc-daily` (namespace: `velero`)
  - 実行頻度: 毎日 18:00 UTC (日本時間 03:00 JST)
  - 保持期間 (TTL): 168時間 (7日間)

### 1.2 対象 PVC と除外方針

本バックアップシステムは、ラベル `backup.pcloud.io/enabled: "true"` が付与された PVC のみを明示的に対象とします。

`clusters/vcluster-app` のPVCマニフェストは vCluster API に適用されます。
vCluster のPVC同期により同じラベルがホスト側の同期PVCにも引き継がれるため、ホストクラスタのVeleroはホスト側PVCだけを対象にします。
仮想PVCとホスト側PVCは別のKubernetesオブジェクトですが、通常は同じ実データ用ボリュームを参照します。
対象PVCには、個別リストアの範囲を限定する `backup.pcloud.io/restore-id` も付与しています。

バックアップ前には、ホストクラスタのコンテキストで同期PVCとラベルを確認してください:

```bash
kubectl get pvc -A -l backup.pcloud.io/enabled=true \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,STORAGE:.spec.resources.requests.storage,PV:.spec.volumeName'
```

このコマンドで対象PVCが確認できない場合は、Veleroのスモークバックアップを実行せず、vClusterの同期状態を先に確認します。

- **バックアップ対象 (初回ロールアウト)**:
  アプリケーションの永続状態を保持する以下の PVC を対象とします。
  - `feed-reader/feed-reader-data`
  - `nostr/nostr-relay-data`
  - `nostr/nostr-bridge-data`

- **意図的除外 PVC**:
  - `pcloud-s3/rclone-s3-cache`: pCloud S3 ゲートウェイ自身の書き戻しキャッシュ。バックアップ対象に含めると循環依存・自己バックアップの危険があるため除外。
  - `llama-cpp/llama-cpp-models`: Hugging Face 等から再取得可能なモデルキャッシュであるため除外。
  - Neon PVC および StatefulSet 生成の PVC: 整合性や復旧手順の個別レビューが必要なため、初期ロールアウトからは除外。

> [!NOTE]
> 本変更を適用しても、**本番バックアップが直ちに自動作成されるわけではありません**。初回バックアップは次回のスケジュール実行時刻 (18:00 UTC) を待つか、後述の手動スモークバックアップによりトリガーします。

---

## 2. 初期セットアップ: 認証情報の設定

Velero の Kopia リポジトリ暗号化キーとして、既存の 1Password `pcloud-s3` アイテムにフィールドを追加します。

### 2.1 1Password へのキー追加

1. ワークステーション等のセキュアな環境で、ランダムなリポジトリ暗号化パスワードを生成します:
   ```bash
   openssl rand -hex 32
   ```
2. 1Password の `k8s` ボールトにある既存アイテム `pcloud-s3` を開きます。
3. フィールド名 `VELERO_REPOSITORY_PASSWORD` を作成し、生成したパスワードを値として保存します。

> [!IMPORTANT]
> 生成したパスワードや認証情報の実値を、Git リポジトリのマニフェスト、コミットメッセージ、ログ等に含めたりコミットしたりしないでください。

### 2.2 ExternalSecrets による自動同期

クラスタ内では、External Secrets Operator が 1Password からシークレットを同期します:
- `velero-s3-credentials`: S3 接続情報 (`cloud` キーに AWS credentials 形式で格納)
- `velero-repo-credentials`: リポジトリ暗号化パスワード (`repository-password` キーに格納)

> [!IMPORTANT]
> `VELERO_REPOSITORY_PASSWORD` を1Passwordに登録するまで `velero-repo-credentials` はReadyにならず、FluxのVelero依存関係が健全化しません。スケジュールを有効にする前に必ず登録とExternalSecretのReady状態を確認してください。

> [!CAUTION]
> `VELERO_REPOSITORY_PASSWORD` は既存のKopiaリポジトリを読み取るための暗号化キーです。既存バックアップが残っている間は値を変更しないでください。変更すると、変更前のバックアップをリストアできなくなる可能性があります。変更が必要な場合は、旧パスワードで既存バックアップを検証したうえで、別のBackupStorageLocationまたは新しいリポジトリへ移行する手順を先に準備してください。

---

## 3. 初期セットアップ: pCloud ストレージの準備

pCloud ゲートウェイ (`rclone-s3-gateway`) は、pCloud アカウント内の `buckets/` ディレクトリを S3 ルートとして公開しています。

### 3.1 バケットディレクトリの確認・作成

S3 バケット `velero-backups` は、pCloud 上のディレクトリ `buckets/velero-backups` に対応します。

1. pCloud Web UI または rclone 等で、`buckets/` 配下に `velero-backups` ディレクトリが存在することを確認します。
2. 存在しない場合は、`buckets/velero-backups` を作成します。

### 3.2 BackupStorageLocation の確認

ゲートウェイおよびバケット準備完了後、Velero の BackupStorageLocation が利用可能であることを確認します:

```bash
kubectl -n velero get backupstoragelocation pcloud
```

`PHASE` が `Available` と表示されていれば正常です。

---

## 4. Flux 同期とヘルスチェック

Flux によるマニフェストの適用状態と各コントローラーの健全性を確認します。

### 4.1 コントローラーレイヤーの確認

```bash
# cluster-controllers Kustomization の確認
kubectl -n flux-system get kustomization cluster-controllers

# Velero Kustomization と HelmRelease の確認
kubectl -n flux-system get kustomization velero
kubectl -n velero get helmrelease velero

# Velero Pod および node-agent の起動確認
kubectl -n velero get pods -o wide
kubectl -n velero get daemonset -l component=velero
```

### 4.2 ExternalSecrets の確認

シークレット値を復号せずにキー名のみを安全に確認します:

```bash
# ExternalSecret リソースの同期状態確認 (Ready=True であること)
kubectl -n velero get externalsecret velero-s3-credentials velero-repo-credentials

# 作成された Secret のキー名を確認 (値は出力しない)
kubectl -n velero get secret velero-s3-credentials -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}'
kubectl -n velero get secret velero-repo-credentials -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}'
```

### 4.3 リソースレイヤーとスケジュールの確認

```bash
# cluster-resources Kustomization の確認
kubectl -n flux-system get kustomization cluster-resources

# pvc-daily スケジュールの確認
kubectl -n velero get schedule pvc-daily
```

---

## 5. 手動スモークバックアップの実行と検証

設定投入後、スケジュールを待たずに動作検証を行うための手動スモークバックアップ手順です。

### 5.1 スモークバックアップの作成

```bash
SMOKE_NAME="smoke-manual-$(date -u +%Y%m%d%H%M%S)"

# ホストクラスタ側に同期された、ラベル付きPVCを確認する
kubectl get pvc -A -l backup.pcloud.io/enabled=true

# velero CLI を利用する場合
velero backup create "${SMOKE_NAME}" --from-schedule pvc-daily

# または kubectl で Backup リソースを直接作成する場合
cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${SMOKE_NAME}
  namespace: velero
spec:
  includedNamespaces:
    - "*"
  includedResources:
    - persistentvolumeclaims
  labelSelector:
    matchLabels:
      backup.pcloud.io/enabled: "true"
  snapshotVolumes: true
  snapshotMoveData: true
  defaultVolumesToFsBackup: false
  storageLocation: pcloud
  ttl: 168h0m0s
  itemOperationTimeout: 6h0m0s
EOF
```

### 5.2 3段階の検証手順

バックアップが確実に成功したことを確認するため、以下の3段階を明確に区別して検証します:

1. **Backup オブジェクトのステータス**:
   ```bash
   kubectl -n velero get backup "${SMOKE_NAME}" -o wide
   ```
   `PHASE` が `Completed` (または一部警告付きの `PartiallyFailed`) に達したことを確認します。

2. **CSI VolumeSnapshot の準備完了**:
   バックアップ処理中、各 PVC の CSI スナップショットが一時的に作成されます:
   ```bash
   kubectl -n velero get volumesnapshots.snapshot.storage.k8s.io -A
   kubectl get volumesnapshotcontent
   ```
   スナップショットが `READYTOUSE=true` になり、データ移動完了後に正常に解放・削除されることを確認します。

3. **Velero DataUpload (データ転送) の完了**:
   CSI スナップショットから pCloud S3 への実際のデータ移動状態を確認します:
   ```bash
   kubectl -n velero get datauploads.velero.io -l velero.io/backup-name="${SMOKE_NAME}"
   ```
   各 PVC に対応する `DataUpload` の `PHASE` が `Completed` となっていることを確認します。
   > [!IMPORTANT]
   > 単に Backup オブジェクトが `Completed` になっただけでは、ボリュームデータが pCloud に到達した十分な証拠にはなりません。必ず `DataUpload` が完了していることを確認してください。

---

## 6. 新規 PVC へのリストア手順 (`scripts/velero-restore-pvc.sh`)

リストア操作は、事故防止のため Flux による自動同期の対象外とし、運用者がオンデマンドで実行するスクリプトとして提供されます。

### 6.1 リストアの実行

`scripts/velero-restore-pvc.sh` を使用して、バックアップから指定した PVC を「新しい名前の PVC」として復元します:

```bash
scripts/velero-restore-pvc.sh <backup-name> <source-namespace> <source-pvc> <target-pvc>
```

クラスタ再構築などで元PVCが存在しない場合は、バックアップ対象PVCに付与していた `restore-id` を明示します:

```bash
scripts/velero-restore-pvc.sh \
  --restore-id <restore-id> \
  <backup-name> <source-namespace> <source-pvc> <target-pvc>
```

`source-namespace` と `source-pvc` には、vCluster内の仮想PVC名ではなく、バックアップに含まれたホスト側同期PVCのnamespaceと名前を指定します。
対象値は、バックアップ前にホストクラスタで次のコマンドを実行して確認できます:

```bash
kubectl get pvc -A -l backup.pcloud.io/enabled=true \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name'
```

実行例 (`<host-namespace>/<host-pvc-name>` のデータを新しいPVCとして復元する場合):
```bash
scripts/velero-restore-pvc.sh smoke-manual-20260909030000 <host-namespace> <host-pvc-name> restored-data
```

このスクリプトは、バックアップ時点の対象PVCに `backup.pcloud.io/restore-id` が存在することを要求します。
ラベル追加前に作成した古いBackupは個別リストアの対象にできないため、ラベル追加後のBackupを使用してください。

### 6.2 スクリプトの安全機構

- **引数の厳格検証**: 4つの位置引数と、指定した場合の `--restore-id` が有効な Kubernetes DNS ラベル (英小文字、数字、ハイフンのみ、最大63文字) であるかを事前検証します。
- **既存リソースの保護**: 対象名前空間内に `target-pvc` が既に存在する場合、スクリプトは直ちに処理を中断します。既存の PVC を削除またはパッチすることは絶対にありません。
- **バックアップの健全性確認**: 指定した Backup のフェーズが `Completed` または `PartiallyFailed` の場合のみリストアを開始します。
- **PVC範囲の限定**: `backup.pcloud.io/restore-id` をRestoreの `labelSelector` に指定し、同じnamespace内の他のPVCを復元しません。
- **名前変更 (リネーム) の適用**: Velero の Resource Modifier (`ConfigMap`) を使用して、指定した `source-pvc` の `/metadata/name` のみを `target-pvc` に安全に置換します。
- **作成失敗時の後処理**: Restoreリソースの作成に失敗した場合、Resource Modifier ConfigMapを自動削除します。

### 6.3 リストア後の確認と切り替え

1. **Restore と DataDownload (データダウンロード) の進行状況確認**:
   リストアの進捗状況および CSI Snapshot Data Movement によるオブジェクトストレージからのデータ転送 (DataDownload) を確認します:
   ```bash
   # Restore リソースのステータス確認
   kubectl -n velero get restore <restore-name> -o wide
   kubectl -n velero describe restore <restore-name>

   # DataDownload リソースの確認 (CSI スナップショットデータ移動の進捗)
   kubectl -n velero get datadownloads.velero.io -l velero.io/restore-name=<restore-name>
   kubectl -n velero get datadownloads.velero.io
   ```
   DataDownload の `PHASE` が `Completed` になり、Restore が `Completed` に達することを確認します。

2. **ホスト側復元PVCのバインド確認**:
   ```bash
   kubectl -n <host-namespace> get pvc restored-data -w
   ```
   ステータスが `Bound` になることを確認します。

3. **データの整合性確認**:
   一時的な検証用 Pod を作成してマウントするか、デバッグ用ワークロードからアクセスしてデータが正常に復元されていることを確認します。

4. **ワークロードの切り替え**:
   ワークロードを新しい PVC に切り替える場合は、Git リポジトリ内の該当 Deployment / StatefulSet マニフェストで `claimName` を更新し、PR を通じて Flux で反映します。
   > [!NOTE]
   > 新しい PVC でのアプリケーション稼働が確認できるまで、元の PVC は削除せず保持してください。

### 6.4 vClusterの既存PVCへ復元データを戻す場合

vClusterの仮想PVCを利用中のワークロードへ戻す場合、復元先の新しいホストPVCへ `claimName` を変更してはいけません。
vClusterは仮想PVCから別のホストPVCを同期作成するため、復元データではなく空のPVCへ接続される可能性があります。

代わりに、`scripts/velero-restore-vcluster-pvc.sh` が作成するステージングPVCから、既存のvCluster同期先ホストPVCへデータをコピーします。
この処理は既存PVCの内容を置き換えるため、対象PVCを使用する仮想クラスタ内のワークロードを先に停止してください。

```bash
scripts/velero-restore-vcluster-pvc.sh \
  --confirm-workload-stopped \
  <backup-name> <host-namespace> <source-host-pvc> <target-host-pvc>
```

通常は `source-host-pvc` と `target-host-pvc` に同じホスト側同期PVCを指定します。
スクリプトは次を検証してから処理します:

- 対象ホストPVCが `Bound` であること
- `vcluster.loft.sh/managed-by: vcluster` とvCluster識別ラベルが存在すること
- Source PVCに `backup.pcloud.io/restore-id` が存在すること
- Velero RestoreとDataDownloadが `Completed` になること

その後、ステージングPVCをマウントしたJobで対象PVCの内容を置き換えます。
コピー完了後にアプリケーションデータを確認し、不要になったステージングPVCを削除してください。

---

## 7. 運用の注意点・ディザスタリカバリ時の挙動

### 7.1 個別PVCリストアの範囲

Velero のリストア仕様上、以下の点に注意してください:

- Restoreには `backup.pcloud.io/restore-id` の完全一致セレクターを設定しているため、対象PVC以外のPVCは復元対象になりません。
- ラベル追加前に作成したBackupは、このセレクターを持たないためスクリプトが開始前に停止します。対象PVCのラベル追加後に新しいBackupを作成してください。
- Restore完了後も、`kubectl describe restore <restore-name>` と作成されたPVCの一覧を確認してからワークロードをアタッチしてください。
- 元PVCが存在しない完全障害復旧では、バックアップ時の `restore-id` を `--restore-id` で指定してください。値は対象PVCマニフェストの `backup.pcloud.io/restore-id` と一致させます。

### 7.2 Resource Modifier ConfigMap のライフサイクル

- スクリプト実行時に `velero` 名前空間内に作成される Resource Modifier ConfigMap (`restore-mod-...`) は、リストア実行中に Velero コントローラーによって参照されます。
- リストアが終端状態 (`Completed`, `Failed`, `PartiallyFailed`) に達する前にこの ConfigMap を削除してはいけません。
- リストア完了後は、スクリプトが出力した削除コマンドを実行して手動で削除してください。Restore作成自体に失敗した場合はスクリプトが自動削除を試みます:
  ```bash
  kubectl -n velero delete configmap <configmap-name>
  ```

---

## 8. トラブルシューティング

### 8.1 pCloud ゲートウェイ障害時

- pCloud S3 ゲートウェイ (`gateway.pcloud-s3.svc.cluster.local:8080`) が一時的に停止した場合、Velero の `BackupStorageLocation` のステータスは `Unavailable` に遷移します。
- スケジュールされたバックアップは明示的に失敗 (`Failed`) します。クラスタ内のローカル Ceph RBD ボリュームや既存データがサイレントに破損・削除されることはありません。
- ゲートウェイ Pod (`kubectl -n pcloud-s3 get pods -l app=rclone-s3-gateway`) のログを確認し、復旧後に `BackupStorageLocation` が `Available` に戻ることを確認してください。

### 8.2 詳細ログの確認コマンド

```bash
# Velero コントローラーログ
kubectl -n velero logs deployment/velero -c velero --tail=100

# Velero node-agent ログ
kubectl -n velero logs daemonset/node-agent -c node-agent --tail=100

# バックアップの詳細情報・ログ
velero backup describe <backup-name> --details
velero backup logs <backup-name>

# リストアの詳細情報・ログ
velero restore describe <restore-name> --details
velero restore logs <restore-name>
```
