#!/usr/bin/env bash
# Strands Decider 2B on Amazon EKS Auto Mode (Graviton, CPU): one entry point.
#
#   cp config.example.env config.env   # edit it
#   ./quickstart.sh up                 # bootstrap + weights + image + cluster + deploy + test (about 20-25 min)
#
# Or step by step:
#   preflight   check tools, credentials, and that the instance types exist in REGION
#   bootstrap   S3 bucket, ECR repo, arm64 CodeBuild project (CloudFormation stack <NAME>-bootstrap)
#   weights     CodeBuild: download the model from the Hugging Face Hub, stage it to s3://<bucket>/model/
#   image       CodeBuild: build the arm64 image, push it to ECR
#   cluster     EKS Auto Mode cluster (eksctl, about 15 min) + free S3 gateway endpoint
#   deploy      NodePools, the Decider (VARIANT), the bench pod; waits until ready
#   test        routing-100 accuracy and latency, then a short concurrency sweep, from inside the cluster
#   agent       deploy the example triage agent (decision model first, Amazon Bedrock below the threshold)
#   threshold   score labeled messages to choose CONFIDENCE_THRESHOLD: threshold [file.jsonl] (default: routing-100)
#   env         print the exports that point kubectl at this cluster: eval "$(./quickstart.sh env)"
#   expose      optional internal Network Load Balancer for callers in the VPC; prints its URL
#   scale N     set the Decider to N pods (0 = scale to zero; idle nodes go after about 3 min)
#   autoscale   add the CPU-based HPA (1-4 pods)
#   status      what is running
#   down        delete the cluster; "down all" also deletes the bootstrap stack and its bucket
#
# Needs: AWS CLI v2, eksctl >= 0.231, kubectl >= 1.35, Python 3.11+, zip. Run from this folder.
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-help}" in up|preflight|bootstrap|weights|image|cluster|deploy|test|agent|threshold|env|expose|scale|autoscale|status|down) ;; *) sed -n '2,23p' "$0"; exit 0 ;; esac
[ -f config.env ] || { echo "Copy config.example.env to config.env and edit it first."; exit 1; }
set -a; source config.env; set +a
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
[ -n "${PROFILE:-}" ] && export AWS_PROFILE="$PROFILE"
export CLUSTER="${NAME}-eks" STACK="${NAME}-bootstrap" KUBECONFIG="$PWD/.kubeconfig-${NAME}"
export ESCALATION_MODEL_ID="${ESCALATION_MODEL_ID:-eu.amazon.nova-2-lite-v1:0}" CONFIDENCE_THRESHOLD="${CONFIDENCE_THRESHOLD:-0.7}"
mkdir -p results

say() { printf '\n== %s\n' "$*"; }
out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
load_stack() {
  export BUCKET=$(out BucketName) LOG_BUCKET=$(out LogBucketName) REPO_URI=$(out RepositoryUri) REPO_NAME=$(out RepositoryName)
  export PROJECT=$(out ProjectName) KEY_ARN=$(out KeyArn)
  # Pods pull the most recently pushed image by digest (tags are immutable; every build gets a new one).
  local digest
  digest=$(aws ecr describe-images --repository-name "$REPO_NAME" --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageDigest' \
           --output text 2>/dev/null || true)
  if [ -n "$digest" ] && [ "$digest" != "None" ]; then export IMAGE_URI="$REPO_URI@$digest"; else export IMAGE_URI=""; fi
}

empty_bucket() {  # $1 = bucket: delete every object version and delete marker (the buckets are versioned)
  local batch
  while :; do
    batch=$(aws s3api list-object-versions --bucket "$1" --max-items 1000 --output json \
            --query '{Objects: [Versions[].{Key: Key, VersionId: VersionId}, DeleteMarkers[].{Key: Key, VersionId: VersionId}][][]}')
    [ "$(printf '%s' "$batch" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["Objects"] or []))')" = "0" ] && break
    aws s3api delete-objects --bucket "$1" --delete "$batch" --output text --query 'length(Errors || `[]`)' >/dev/null
  done
}

vcpus() {  # export VCPU_LARGE / VCPU_SMALL for the configured instance types
  export VCPU_LARGE=$(aws ec2 describe-instance-types --instance-types "$INSTANCE_LARGE" --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text)
  export VCPU_SMALL=$(aws ec2 describe-instance-types --instance-types "$INSTANCE_SMALL" --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text)
}

cmd_preflight() {
  say "preflight: tools, credentials, instance types in $REGION"
  for t in aws eksctl kubectl python3 zip curl; do command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }; done
  aws sts get-caller-identity --query Arn --output text
  local it n
  for it in "$INSTANCE_LARGE" "$INSTANCE_SMALL" "$INSTANCE_BENCH"; do
    n=$(aws ec2 describe-instance-type-offerings --location-type region --filters Name=instance-type,Values="$it" \
          --query 'length(InstanceTypeOfferings)' --output text)
    [ "$n" = "1" ] || { echo "$it is not offered in $REGION: change INSTANCE_* in config.env"; exit 1; }
    echo "$it ok"
  done
}

codebuild() {  # $1 = JOB (weights|image)
  load_stack
  rm -f /tmp/qs-eks.zip
  zip -qr /tmp/qs-eks.zip . -x 'config.env' '.kubeconfig*' 'results/*' '*__pycache__*' '.git*'
  aws s3 cp /tmp/qs-eks.zip "s3://$BUCKET/source/eks.zip" --only-show-errors
  local id
  id=$(aws codebuild start-build --project-name "$PROJECT" \
        --environment-variables-override name=JOB,value="$1" name=MODEL_ID,value="$MODEL_ID" \
          name=BASE_MODEL_ID,value="$BASE_MODEL_ID" name=IMAGE_TAG,value="$(date -u +%Y%m%d-%H%M%S)" \
          name=MODEL_REVISION,value="${MODEL_REVISION:-}" name=BASE_MODEL_REVISION,value="${BASE_MODEL_REVISION:-}" \
          name=DECIDER_VERSION,value="$DECIDER_VERSION" \
        --query build.id --output text)
  echo "CodeBuild $1: $id"
  local st=IN_PROGRESS
  while [ "$st" = "IN_PROGRESS" ]; do
    sleep 20
    st=$(aws codebuild batch-get-builds --ids "$id" --query 'builds[0].buildStatus' --output text)
    printf '.'
  done
  echo " $st"
  [ "$st" = "SUCCEEDED" ] || { echo "Build failed: see CloudWatch log group /aws/codebuild/${NAME}-build"; exit 1; }
}

cmd_bootstrap() {
  say "bootstrap: stack $STACK"
  aws cloudformation deploy --stack-name "$STACK" --template-file bootstrap.yaml \
    --capabilities CAPABILITY_IAM --parameter-overrides Name="$NAME" --no-fail-on-empty-changeset
  load_stack; echo "bucket $BUCKET, repo $REPO_URI, project $PROJECT"
}
cmd_weights() { say "weights: $MODEL_ID + $BASE_MODEL_ID -> S3"; codebuild weights; }
cmd_image()   { say "image: build and push"; codebuild image; load_stack; echo "image $IMAGE_URI"; }

cmd_cluster() {
  load_stack
  if [ "$API_CIDRS" = "auto" ]; then API_CIDRS="$(curl -s https://checkip.amazonaws.com | tr -d '\n')/32"; fi
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  export API_CIDRS ACCOUNT_ID
  say "cluster: $CLUSTER (API access from $API_CIDRS)"
  python3 render.py cluster > "results/cluster-${CLUSTER}.yaml"
  if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
    echo "exists"; eksctl utils write-kubeconfig --cluster "$CLUSTER" --kubeconfig "$KUBECONFIG"
  else
    eksctl create cluster -f "results/cluster-${CLUSTER}.yaml" --kubeconfig "$KUBECONFIG"
  fi
  # Free S3 gateway endpoint, so the weight copy at pod start goes straight to S3, not through the NAT.
  local vpc
  local -a rts
  vpc=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
  if [ "$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$vpc" Name=service-name,Values="com.amazonaws.$REGION.s3" \
          --query 'length(VpcEndpoints)' --output text)" = "0" ]; then
    read -ra rts <<< "$(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$vpc" --query 'RouteTables[].RouteTableId' --output text)"
    aws ec2 create-vpc-endpoint --vpc-id "$vpc" --vpc-endpoint-type Gateway --service-name "com.amazonaws.$REGION.s3" \
      --route-table-ids "${rts[@]}" --query VpcEndpoint.VpcEndpointId --output text \
      --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=project,Value=$NAME},{Key=Name,Value=$CLUSTER-s3}]"
  else
    echo "S3 gateway endpoint already in $vpc"
  fi
}

cmd_deploy() {
  load_stack
  say "deploy: $VARIANT"
  vcpus
  python3 render.py nodepools | kubectl apply -f -
  kubectl -n decider scale deploy/decider --replicas=0 >/dev/null 2>&1 || true
  kubectl -n decider wait --for=delete pod -l app=decider --timeout=300s >/dev/null 2>&1 || true
  python3 render.py decider --variant "$VARIANT" | kubectl apply -f -
  kubectl -n decider get pod bench >/dev/null 2>&1 || python3 render.py bench | kubectl apply -f -
  kubectl -n decider rollout status deploy/decider --timeout=900s
  kubectl -n decider wait --for=condition=Ready pod/bench --timeout=600s
  kubectl -n decider get pods -o wide
}

cmd_test() {
  say "test: routing-100 (accuracy and latency), then concurrency 1,2,4,8"
  kubectl -n decider exec bench -- python /bench/bench/load.py --url http://decider:8080 \
    --label acc --concurrency 1 --requests 100 --warmup 2
  kubectl -n decider exec bench -- python /bench/bench/load.py --url http://decider:8080 \
    --label sweep --concurrency 1,2,4,8 --requests 48 --warmup 4
  for f in $(kubectl -n decider exec bench -- sh -c 'ls /bench/results/raw/'); do
    kubectl -n decider cp "bench:/bench/results/raw/$f" "results/$f" >/dev/null
  done
  echo "results in $PWD/results/"
}

cmd_expose() {
  say "expose: internal Network Load Balancer (reachable from inside the VPC only)"
  local vpc
  if [ -z "${NLB_CIDRS:-}" ]; then
    vpc=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
    NLB_CIDRS=$(aws ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[0].CidrBlock' --output text)
  fi
  export NLB_CIDRS
  echo "accepting connections from $NLB_CIDRS only"
  python3 render.py nlb | kubectl apply -f -
  local h=""
  for i in $(seq 1 60); do
    h=$(kubectl -n decider get svc decider-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    [ -n "$h" ] && break; sleep 5
  done
  echo "NLB: http://$h/invocations  (DNS and targets can take 2-3 minutes to become healthy)"
}

cmd_agent() {
  load_stack
  say "agent: example triage agent (escalates below $CONFIDENCE_THRESHOLD to $ESCALATION_MODEL_ID)"
  python3 render.py agent | kubectl apply -f -
  kubectl -n decider rollout status deploy/agent --timeout=600s
}
cmd_threshold() {
  local path=/bench/data/routing-100.jsonl
  if [ -n "${1:-}" ]; then  # a file on this machine: copy it into the bench pod first
    kubectl -n decider cp "$1" bench:/bench/results/labeled.jsonl
    path=/bench/results/labeled.jsonl
  fi
  say "threshold: route confidence on labeled messages (${1:-the routing-100 set})"
  kubectl -n decider exec bench -- sh -c "cd /app/agent && python threshold.py $path"
}
cmd_env() {
  echo "export KUBECONFIG=\"$KUBECONFIG\" AWS_REGION=\"$REGION\"${PROFILE:+ AWS_PROFILE=\"$PROFILE\"}"
}

cmd_scale()     { kubectl -n decider scale deploy/decider --replicas="${1:?replicas}"; }
cmd_autoscale() { kubectl apply -f k8s/hpa.yaml; kubectl -n decider get hpa; }
cmd_status() {
  load_stack
  echo "stack $STACK: bucket $BUCKET, image $IMAGE_URI"
  aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text 2>/dev/null || echo "no cluster"
  kubectl get nodes -L node.kubernetes.io/instance-type 2>/dev/null || true
  kubectl -n decider get deploy,pods,hpa,svc 2>/dev/null || true
}
cmd_down() {
  say "down: cluster $CLUSTER"
  if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
    # Load balancers and the S3 endpoint were created outside eksctl's stacks; remove them first or the
    # VPC can't be deleted.
    kubectl -n decider delete svc decider-nlb --ignore-not-found --wait=true >/dev/null 2>&1 || true
    local vpc
    local -a eps
    vpc=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
    read -ra eps <<< "$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$vpc" --query 'VpcEndpoints[].VpcEndpointId' --output text)"
    if [ "${#eps[@]}" -gt 0 ]; then aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${eps[@]}" >/dev/null; sleep 30; fi
    eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait
    # EKS creates the control plane log group itself, so eksctl leaves it behind.
    aws logs delete-log-group --log-group-name "/aws/eks/$CLUSTER/cluster" 2>/dev/null || true
  fi
  if [ "${1:-}" = "all" ]; then
    load_stack
    say "down all: emptying s3://$BUCKET and s3://$LOG_BUCKET (all versions) and deleting stack $STACK"
    empty_bucket "$BUCKET"
    empty_bucket "$LOG_BUCKET"
    aws cloudformation delete-stack --stack-name "$STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK"
  fi
}
cmd_up() { cmd_preflight; cmd_bootstrap; cmd_weights; cmd_image; cmd_cluster; cmd_deploy; cmd_test; }

c=${1:-help}; shift || true
case "$c" in
  up|preflight|bootstrap|weights|image|cluster|deploy|test|agent|threshold|env|expose|scale|autoscale|status|down) "cmd_$c" "$@" ;;
  *) sed -n '2,23p' "$0" ;;
esac
