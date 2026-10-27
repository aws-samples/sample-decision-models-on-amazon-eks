# Strands Decider Deployment, PodDisruptionBudget and Service. Rendered by render.py (string.Template placeholders).
# One process per pod, one request at a time per pod (the app serialises requests: overlapping forwards
# fight for the same cores), so throughput comes from pods, and threads per pod decide latency.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: decider
  namespace: decider
  labels: {app: decider}
  annotations:
    checkov.io/skip1: "CKV_K8S_11=No CPU limit by design, so torch threads are never throttled by the CFS quota; the CPU request reserves the cores."
    checkov.io/skip2: "CKV_K8S_8=No liveness probe by design; a busy pod can answer late, and restarting it would only lose work. Startup and readiness probes check the port."
    checkov.io/skip3: "CKV2_K8S_6=No NetworkPolicy because on EKS Auto Mode (Oct 2026) policy changes did not reach running pods, so new agent pods could not reach running decider pods until those restarted. See README."
spec:
  replicas: ${REPLICAS}
  strategy: {type: RollingUpdate, rollingUpdate: {maxSurge: 1, maxUnavailable: 0}}
  selector:
    matchLabels: {app: decider}
  template:
    metadata:
      labels: {app: decider, decider/variant: "${VARIANT}"}
    spec:
      serviceAccountName: decider
      # The server never calls the Kubernetes API. EKS Pod Identity mounts its own token for AWS access.
      automountServiceAccountToken: false
      nodeSelector: {decider/pool: "${POOL}", kubernetes.io/arch: arm64}
      tolerations:
        - {key: decider, operator: Equal, value: "true", effect: NoSchedule}
      # Room for the preStop sleep below, then for the request in flight to finish.
      terminationGracePeriodSeconds: 60
      # Run as the image's non-root user.
      securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001}
      volumes:
        - name: model
          emptyDir: ${MODEL_VOLUME}
        - name: tmp
          emptyDir: {sizeLimit: 1Gi}
      containers:
        - name: decider
          image: ${IMAGE}
          imagePullPolicy: Always  # the image is pinned by digest, so this only checks the registry
          ports: [{name: http, containerPort: 8080}]
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            seccompProfile: {type: RuntimeDefault}
          env:
            - {name: BIND_HOST, value: "0.0.0.0"}  # inside the pod; reachable only through the Services
            - {name: WEIGHTS_S3_URI, value: "${WEIGHTS_S3_URI}"}
            - {name: MODEL_NAME, value: "${MODEL_NAME}"}
            - {name: MODEL_DIR, value: /opt/model}
            - {name: DECIDER_CPU_DTYPE, value: "${DTYPE}"}
            - {name: DECIDER_THREADS, value: "${THREADS}"}
            - {name: OMP_NUM_THREADS, value: "${THREADS}"}
            - {name: AWS_REGION, value: "${REGION}"}
            - {name: AWS_DEFAULT_REGION, value: "${REGION}"}
            - {name: HOME, value: /tmp}  # the root filesystem is read-only; caches go to the tmp volume
          volumeMounts:
            - {name: model, mountPath: /opt/model}
            - {name: tmp, mountPath: /tmp}
          # No CPU limit, so torch threads are never throttled by the CFS quota; the request reserves
          # the cores. The memory limit protects the node (fp32 peaks at about 9.2 GB).
          resources:
            requests: {cpu: "${CPU}", memory: "${MEM_REQUEST}"}
            limits: {memory: "${MEM_LIMIT}"}
          # The port opens only once the model has loaded. After that, check just the port: /ping shares
          # the server's thread pool with requests waiting for the lock, so a busy pod can answer it late,
          # and taking that pod out of the Service, or restarting it, would only lose work.
          startupProbe:
            tcpSocket: {port: http}
            periodSeconds: 5
            failureThreshold: 180
          readinessProbe:
            tcpSocket: {port: http}
            periodSeconds: 5
          # A stopping pod keeps serving for 30 s while the Service and any load balancer stop sending it
          # new connections; without this, a request can wait minutes on TCP retries.
          lifecycle:
            preStop: {exec: {command: ["sleep", "30"]}}
---
# Node replacements (Auto Mode expiry and drift) evict one pod at a time, so with 2 or more pods one
# keeps serving. With one pod, maxUnavailable 1 still lets the node drain.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: decider
  namespace: decider
spec:
  maxUnavailable: 1
  selector:
    matchLabels: {app: decider}
---
apiVersion: v1
kind: Service
metadata:
  name: decider
  namespace: decider
spec:
  selector: {app: decider}
  ports: [{name: http, port: 8080, targetPort: http}]
