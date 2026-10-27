# The example triage agent (examples/agent/triage.py), rendered by render.py. It asks the decision model first
# and escalates low-confidence messages to a foundation model on Amazon Bedrock, with EKS Pod Identity
# (service account "agent"; cluster.yaml.tpl grants it bedrock:InvokeModel* on ESCALATION_MODEL_ID only).
# Reachable only inside the cluster (ClusterIP). Runs on the small arm64 bench pool.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent
  namespace: decider
  labels: {app: agent}
  annotations:
    checkov.io/skip1: "CKV2_K8S_6=No NetworkPolicy because on EKS Auto Mode (Oct 2026) policy changes did not reach running pods, so new agent pods could not reach running decider pods until those restarted. See README."
spec:
  replicas: 1
  selector:
    matchLabels: {app: agent}
  template:
    metadata:
      labels: {app: agent}
    spec:
      serviceAccountName: agent
      # The agent never calls the Kubernetes API. EKS Pod Identity mounts its own token for AWS access.
      automountServiceAccountToken: false
      nodeSelector: {decider/role: bench}
      tolerations:
        - {key: decider-bench, operator: Equal, value: "true", effect: NoSchedule}
      securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001}
      volumes:
        - name: tmp
          emptyDir: {sizeLimit: 256Mi}
      containers:
        - name: agent
          image: ${IMAGE}
          imagePullPolicy: Always  # the image is pinned by digest, so this only checks the registry
          command: ["python", "/app/agent/triage.py"]
          ports: [{name: http, containerPort: 8080}]
          env:
            - {name: BIND_HOST, value: "0.0.0.0"}  # inside the pod; reachable only through the ClusterIP Service
            - {name: DECIDER_URL, value: "http://decider:8080"}
            - {name: ESCALATION_MODEL_ID, value: "${ESCALATION_MODEL_ID}"}
            - {name: CONFIDENCE_THRESHOLD, value: "${CONFIDENCE_THRESHOLD}"}
            - {name: AWS_REGION, value: "${REGION}"}
            - {name: HOME, value: /tmp}  # the root filesystem is read-only
          volumeMounts:
            - {name: tmp, mountPath: /tmp}
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
            seccompProfile: {type: RuntimeDefault}
          resources:
            requests: {cpu: 250m, memory: 512Mi}
            limits: {cpu: "1", memory: 1Gi}
          readinessProbe:
            httpGet: {path: /ping, port: http}
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /ping, port: http}
            periodSeconds: 30
            timeoutSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: agent
  namespace: decider
spec:
  selector: {app: agent}
  ports: [{name: http, port: 8080, targetPort: http}]
