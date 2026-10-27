# EKS Auto Mode cluster for Strands Decider 2B on Graviton (CPU). Create with:
#   ./quickstart.sh cluster      (renders this template from config.env, then runs eksctl >= 0.231)
# Auto Mode manages compute, networking, storage and the load balancer controller. The Decider and
# bench pods run on our own arm64 NodePools (k8s/nodepools.yaml); the built-in general-purpose pool is amd64 only.
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER}
  region: ${REGION}
  version: "${K8S_VERSION}"
  tags:
    project: ${NAME}
autoModeConfig:
  enabled: true
  nodePools: [general-purpose, system]
vpc:
  nat:
    gateway: Single
  clusterEndpoints:
    publicAccess: true
    privateAccess: true
  # Who may reach the Kubernetes API (config.env API_CIDRS).
  publicAccessCIDRs: [${API_CIDRS}]
iam:
  podIdentityAssociations:
    - namespace: decider
      serviceAccountName: decider
      createServiceAccount: true
      roleName: ${CLUSTER}-pod-role
      permissionPolicy:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Action: ["s3:GetObject"]
            Resource: ["arn:aws:s3:::${BUCKET}/model/*"]
          - Effect: Allow
            Action: ["s3:ListBucket"]
            Resource: ["arn:aws:s3:::${BUCKET}"]
            Condition:
              StringLike:
                s3:prefix: ["model/*", "model"]
          # The bucket is encrypted with the sample's KMS key; decrypt only through S3.
          - Effect: Allow
            Action: ["kms:Decrypt"]
            Resource: ["${KEY_ARN}"]
            Condition:
              StringEquals:
                kms:ViaService: ["s3.${REGION}.amazonaws.com"]
    # The example triage agent (k8s/agent.yaml.tpl) may call only the escalation model on Amazon Bedrock.
    - namespace: decider
      serviceAccountName: agent
      createServiceAccount: true
      roleName: ${CLUSTER}-agent-role
      permissionPolicy:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Action: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
            Resource:
              - "arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:inference-profile/${ESCALATION_MODEL_ID}"
              - "arn:aws:bedrock:*::foundation-model/${ESCALATION_BASE_MODEL}"
addons:
  - name: metrics-server
cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator"]
    logRetentionInDays: 7
