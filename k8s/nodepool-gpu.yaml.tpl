# Optional NVIDIA GPU NodePool for EKS Auto Mode (rendered with the others when INSTANCE_GPU is set).
# Auto Mode installs the NVIDIA driver and device plugin itself; pods ask for nvidia.com/gpu.
# GPU instances are amd64, so the gpu variant uses the GPU image (./quickstart.sh image gpu).
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: decider-gpu
spec:
  template:
    metadata:
      labels: {decider/pool: gpu}
    spec:
      nodeClassRef: {group: eks.amazonaws.com, kind: NodeClass, name: default}
      requirements:
        - {key: node.kubernetes.io/instance-type, operator: In, values: ["${INSTANCE_GPU}"]}
        - {key: kubernetes.io/arch, operator: In, values: ["amd64"]}
        - {key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"]}
      taints:
        - {key: decider, value: "true", effect: NoSchedule}
        - {key: nvidia.com/gpu, effect: NoSchedule}
      expireAfter: 168h
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 2m
  limits:
    cpu: "${CPU_LIMIT_GPU}"
