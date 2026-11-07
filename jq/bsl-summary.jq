# kubectl get backupstoragelocations.velero.io -o json | jq -r -f jq/bsl-summary.jq
(["NAME","PHASE","ACCESS","BUCKET","S3URL","LAST_SYNC"] | @tsv),
(.items[]
  | [ .metadata.name,
      (.status.phase // "-"),
      (.spec.accessMode // "ReadWrite"),
      (.spec.objectStorage.bucket // "-"),
      (.spec.config.s3Url // "-"),
      (.status.lastSyncedTime // "-") ]
  | @tsv)
