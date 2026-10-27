# Optional: an internal Network Load Balancer in front of the Decider, for callers in the cluster's VPC (add
# peered or on-premises CIDRs with NLB_CIDRS). EKS Auto Mode provisions it (loadBalancerClass eks.amazonaws.com/nlb).
# The Decider has no authentication of its own: keep this internal, and add auth (for example an API
# gateway or a service mesh) before exposing it any wider. Rendered by render.py (NLB_CIDRS).
#   ./quickstart.sh expose        # applies this and prints the NLB's DNS name
apiVersion: v1
kind: Service
metadata:
  name: decider-nlb
  namespace: decider
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    # Pods are few and can sit in one zone, so every zone of the NLB sends to all of them. A stopping pod
    # drains for 30 s, while its preStop sleep keeps it serving.
    service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: deregistration_delay.timeout_seconds=30
spec:
  type: LoadBalancer
  loadBalancerClass: eks.amazonaws.com/nlb
  # Only these addresses can connect; without this the security group allows 0.0.0.0/0.
  loadBalancerSourceRanges: [${NLB_CIDRS}]
  selector: {app: decider}
  ports: [{name: http, port: 80, targetPort: http}]
