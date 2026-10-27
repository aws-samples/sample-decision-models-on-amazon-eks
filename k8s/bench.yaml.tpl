# A long-running bench pod on its own small Graviton pool (same image, so it has bench/ and data/).
# Run tests with: kubectl -n decider exec bench -- python /bench/bench/load.py --url http://decider:8080 ...
apiVersion: v1
kind: Pod
metadata:
  name: bench
  namespace: decider
  labels: {app: bench}
  annotations:
    checkov.io/skip1: "CKV_K8S_8=Test client that sleeps until you exec into it; it serves nothing to probe."
    checkov.io/skip2: "CKV_K8S_9=Test client that sleeps until you exec into it; it serves nothing to probe."
    checkov.io/skip3: "CKV2_K8S_6=No NetworkPolicy because on EKS Auto Mode (Oct 2026) policy changes did not reach running pods, so new agent pods could not reach running decider pods until those restarted. See README."
spec:
  nodeSelector: {decider/role: bench}
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001}
  volumes:
    - name: results
      emptyDir: {sizeLimit: 1Gi}
    - name: tmp
      emptyDir: {sizeLimit: 256Mi}
  tolerations:
    - {key: decider-bench, operator: Equal, value: "true", effect: NoSchedule}
  containers:
    - name: bench
      image: ${IMAGE}
      imagePullPolicy: Always  # the image is pinned by digest, so this only checks the registry
      command: ["sleep", "infinity"]
      env:
        - {name: HOME, value: /tmp}  # the root filesystem is read-only
      volumeMounts:
        - {name: results, mountPath: /bench/results}
        - {name: tmp, mountPath: /tmp}
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        seccompProfile: {type: RuntimeDefault}
      resources:
        requests: {cpu: "1", memory: 1Gi}
        limits: {cpu: "1", memory: 1Gi}
  restartPolicy: Never
