# kubectl get backups.velero.io -o json | jq -r -f jq/backup-summary.jq
(["NAME","PHASE","STARTED","COMPLETED","ITEMS","ERRORS","WARNINGS","EXPIRES"] | @tsv),
(.items
  | sort_by(.status.startTimestamp // "")
  | .[]
  | [ .metadata.name,
      (.status.phase // "-"),
      (.status.startTimestamp // "-"),
      (.status.completionTimestamp // "-"),
      ((.status.progress.itemsBackedUp // 0) | tostring),
      ((.status.errors // 0) | tostring),
      ((.status.warnings // 0) | tostring),
      (.status.expiration // "-") ]
  | @tsv)
