# kubectl get podvolumebackups.velero.io -o json | jq -r -f jq/podvolume-summary.jq
# (also works for podvolumerestores.velero.io)
(["NAME","PARENT","POD","VOLUME","PHASE","BYTES_DONE","UPLOADER"] | @tsv),
(.items[]
  | [ .metadata.name,
      (.metadata.labels["velero.io/backup-name"] // .metadata.labels["velero.io/restore-name"] // "-"),
      ((.spec.pod.namespace // "-") + "/" + (.spec.pod.name // "-")),
      (.spec.volume // "-"),
      (.status.phase // "-"),
      ((.status.progress.bytesDone // 0) | tostring),
      (.spec.uploaderType // "-") ]
  | @tsv)
