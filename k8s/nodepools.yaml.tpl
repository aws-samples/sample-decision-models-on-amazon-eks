# arm64 NodePools for EKS Auto Mode, rendered from config.env by render.py:
#   decider-large  INSTANCE_LARGE (several Decider pods share one big node: lowest latency, most throughput per node)
#   decider-small  INSTANCE_SMALL (one Decider pod per node: small scaling steps)
#   decider-bench  INSTANCE_BENCH (the test client and the example agent; the built-in general-purpose pool is amd64 only)
# All are tainted so nothing else lands there, capped as a cost guard (MAX_NODES each), and give back empty
# nodes after 2 minutes.
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: decider-large
spec:
  template:
    metadata:
      labels: {decider/pool: large}
    spec:
      nodeClassRef: {group: eks.amazonaws.com, kind: NodeClass, name: default}
      requirements:
        - {key: node.kubernetes.io/instance-type, operator: In, values: ["${INSTANCE_LARGE}"]}
        - {key: kubernetes.io/arch, operator: In, values: ["arm64"]}
        - {key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"]}
      taints:
        - {key: decider, value: "true", effect: NoSchedule}
      expireAfter: 168h
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 2m
  limits:
    cpu: "${CPU_LIMIT_LARGE}"
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: decider-small
spec:
  template:
    metadata:
      labels: {decider/pool: small}
    spec:
      nodeClassRef: {group: eks.amazonaws.com, kind: NodeClass, name: default}
      requirements:
        - {key: node.kubernetes.io/instance-type, operator: In, values: ["${INSTANCE_SMALL}"]}
        - {key: kubernetes.io/arch, operator: In, values: ["arm64"]}
        - {key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"]}
      taints:
        - {key: decider, value: "true", effect: NoSchedule}
      expireAfter: 168h
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 2m
  limits:
    cpu: "${CPU_LIMIT_SMALL}"
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: decider-bench
spec:
  template:
    metadata:
      labels: {decider/role: bench}
    spec:
      nodeClassRef: {group: eks.amazonaws.com, kind: NodeClass, name: default}
      requirements:
        - {key: node.kubernetes.io/instance-type, operator: In, values: ["${INSTANCE_BENCH}"]}
        - {key: kubernetes.io/arch, operator: In, values: ["arm64"]}
        - {key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"]}
      taints:
        - {key: decider-bench, value: "true", effect: NoSchedule}
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 2m
  limits:
    cpu: "16"
