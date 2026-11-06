# auth-api on EKS - Kubernetes Manifests + Helm Chart

Production deployment of the `auth-api` microservice (REST API for authentication/authorization)
on an existing EKS 1.28 cluster. Delivered twice, deliberately:

| Path | What it is |
|---|---|
| `k8s/` | Plain, readable manifests (one object per file) - deploy with `kubectl` |
| `helm/auth-api/` | The same objects as a templated Helm chart with `values-dev/staging/prod.yaml` |

## Architecture

```
                         Internet
                            |
                  AWS NLB / ELB  (public)
                            |
              +-------------v--------------+
              |  ingress-nginx  (namespace  |   TLS terminated here (cert from cert-manager)
              |  ingress-nginx)             |   HTTP->HTTPS redirect, 100 rps/IP, CORS
              +-------------+---------------+
                            |  NetworkPolicy: only this namespace, only :3000
  ======================  namespace: auth-api  =========================================
              +-------------v---------------+
              | Service auth-api  ClusterIP |   80 -> 3000
              +-------------+---------------+
          +-----------------+-----------------+
   +------v-----+     +-----v------+     +----v-------+
   | auth-api   |     | auth-api   |     | auth-api   |   Deployment, 3..20 pods (HPA @70% CPU)
   | pod (AZ-a) |     | pod (AZ-b) |     | pod (AZ-c) |   spread over zones/nodes, PDB minAvailable=2
   +------+-----+     +-----+------+     +----+-------+
          |   NetworkPolicy egress: DNS, RDS:5432, ElastiCache:6379 only
  ==========|=================|=================|=========================================
            v                 v                 v
     kube-dns (53)     RDS PostgreSQL     ElastiCache Redis       (outside Kubernetes)
```

Objects: Namespace, ServiceAccount, ConfigMap (JSON app config), Secret (`DATABASE_URL`, `REDIS_URL`),
Deployment, Service, Ingress, HPA, PodDisruptionBudget, NetworkPolicy.

### How each requirement is met

| Requirement | Where / how |
|---|---|
| 3+ replicas, rolling update `maxSurge 1 / maxUnavailable 0` | `03-deployment.yaml` - a new pod must be Ready before an old one is removed = zero downtime |
| Requests 250m/256Mi, limits 500m/512Mi | Deployment `resources` (no limits = noisy-neighbour/OOM risk) |
| Env: `DATABASE_URL`, `REDIS_URL` from Secret; `LOG_LEVEL=info`, `NODE_ENV=production` | `secretKeyRef` + literal env |
| Startup / liveness / readiness probes on :3000 | `/health/startup` (initialDelay 10s), `/health/live`, `/health/ready` |
| Graceful shutdown | `terminationGracePeriodSeconds: 30` + `preStop: sleep 10` so the ingress stops routing before SIGTERM |
| Service ClusterIP 80 -> 3000 | `04-service.yaml` |
| Ingress: nginx, host, TLS, rate limit, CORS, SSL redirect | `05-ingress.yaml` annotations |
| HPA 3-20 @ 70% CPU, down 300s / up 60s | `06-hpa.yaml` (autoscaling/v2 `behavior`) |
| ConfigMap JSON, Secret, PDB `minAvailable: 2` | `02-configmap.yaml`, `examples/secret.example.yaml`, `07-pdb.yaml` |
| NetworkPolicy: in from `ingress-nginx`; out to RDS, ElastiCache, DNS | `08-networkpolicy.yaml` - everything else is denied |
| Helm chart, parameterised, dev/staging/prod | `helm/auth-api/` |

Extra hardening (not requested, cheap and standard): non-root user, read-only root filesystem, all Linux
capabilities dropped, `seccomp: RuntimeDefault`, no ServiceAccount token mounted, topology spread across
zones/nodes, namespace enforces the Pod Security `restricted` profile.

## Prerequisites

- `kubectl` >= 1.28 configured for the target EKS cluster (`aws eks update-kubeconfig --name <cluster> --region us-west-2`)
- `helm` >= 3.12
- Already installed in the cluster: **ingress-nginx**, **metrics-server** (required by the HPA),
  **cert-manager** (+ `aws-privateca-issuer` and an `AWSPCAClusterIssuer` named `aws-pca-issuer`)
- **Network policy enforcement** enabled: on EKS enable it in the VPC CNI
  (`aws eks update-addon --addon-name vpc-cni --configuration-values '{"enableNetworkPolicy":"true"}'`) or run Calico/Cilium.
  Without an enforcing CNI the NetworkPolicy is silently ignored.
- Image pull: nodes' IAM role can read ECR repo `auth-api` in account `123456789012`
- Replace the placeholder CIDRs (`10.0.20.0/24` RDS, `10.0.30.0/24` ElastiCache) with the real subnet CIDRs

## Deploy with kubectl

```bash
# 1. Namespace first
kubectl apply -f k8s/00-namespace.yaml

# 2. Secret - created out-of-band, NEVER committed (see k8s/examples/secret.example.yaml)
kubectl -n auth-api create secret generic auth-api-secrets \
  --from-literal=DATABASE_URL='postgresql://USER:PASS@<rds-endpoint>:5432/authdb' \
  --from-literal=REDIS_URL='redis://default:PASS@<elasticache-endpoint>:6379'

# 3. Everything else (files are numbered in dependency order)
kubectl apply -f k8s/

# 4. Watch it come up
kubectl -n auth-api rollout status deployment/auth-api
kubectl -n auth-api get deploy,po,svc,ingress,hpa,pdb,networkpolicy
```

Nothing in `k8s/` contains a real credential; `kubectl apply -f k8s/` does not touch `k8s/examples/`.

## Deploy with Helm

Same chart for every environment, only the values file changes:

```bash
cd helm/auth-api
helm lint . -f values-prod.yaml                      # static checks
helm template auth-api . -f values-prod.yaml | less  # inspect what will be applied

# dev  (chart creates a placeholder Secret from values-dev.yaml - dev only!)
helm upgrade --install auth-api . -n auth-api-dev --create-namespace -f values-dev.yaml

# staging  (Secret `auth-api-secrets` must already exist in the namespace)
helm upgrade --install auth-api . -n auth-api-staging --create-namespace -f values-staging.yaml \
  --set image.tag=v1.2.3 --atomic --timeout 5m

# prod
helm upgrade --install auth-api . -n auth-api -f values-prod.yaml \
  --set image.tag=v1.2.3 --atomic --timeout 5m
```

`--atomic` rolls back automatically if the new pods never become Ready.

Parameterised: image repo/tag, replica count, resources, env vars (`env:` map + `extraEnv:`), ingress host / TLS /
rate limit / CORS, autoscaling, PDB, network policy CIDRs, probes, app config JSON.
Staging and prod keep `secret.create=false` so credentials never pass through Helm values or release history.

**Chart design notes**
- When `autoscaling.enabled`, the Deployment omits `replicas` so `helm upgrade` doesn't reset what the HPA scaled to.
- The pod template carries `checksum/config` (and `checksum/secret` in dev) annotations: changing config rolls the pods.
- Selectors use only `name` + `instance` labels (immutable once created).

## Test the deployment

```bash
# Pods Ready, probes passing
kubectl -n auth-api get pods -o wide
kubectl -n auth-api describe deploy/auth-api | grep -A3 -E "Replicas|Liveness|Readiness|Startup"

# Through the port-forward (bypasses ingress)
kubectl -n auth-api port-forward svc/auth-api 8080:80 &
curl -i localhost:8080/health/live
curl -i localhost:8080/health/ready

# Through the ingress (TLS, redirect, CORS)
curl -I  http://auth-api.example.com/health/live        # expect 308 -> https
curl -i  https://auth-api.example.com/health/live        # expect 200
curl -i -X OPTIONS https://auth-api.example.com/ \
  -H 'Origin: https://app.example.com' -H 'Access-Control-Request-Method: POST'   # expect Access-Control-Allow-Origin
curl -i -X OPTIONS https://auth-api.example.com/ -H 'Origin: https://evil.example' \
  -H 'Access-Control-Request-Method: POST'                                         # expect NO allow-origin header

# Certificate issued?
kubectl -n auth-api get certificate,secret auth-api-tls

# Autoscaling (needs metrics-server)
kubectl -n auth-api get hpa auth-api -w

# Zero-downtime rollout: run a request loop while rolling
kubectl -n auth-api rollout restart deploy/auth-api
while true; do curl -s -o /dev/null -w "%{http_code}\n" https://auth-api.example.com/health/ready; sleep 0.2; done

# PDB: a drain must never go below 2 ready pods
kubectl -n auth-api get pdb auth-api

# NetworkPolicy: a random pod must NOT reach the API; DNS must still work
kubectl run np-test --rm -it --restart=Never --image=busybox -n default -- wget -qO- -T3 http://auth-api.auth-api.svc/   # should time out
```

## Rollback procedure

```bash
# kubectl
kubectl -n auth-api rollout history deploy/auth-api
kubectl -n auth-api rollout undo deploy/auth-api                 # previous revision
kubectl -n auth-api rollout undo deploy/auth-api --to-revision=3
kubectl -n auth-api rollout status deploy/auth-api

# Helm
helm history auth-api -n auth-api
helm rollback auth-api <REVISION> -n auth-api --wait
```

Because `maxUnavailable: 0`, a bad release (pods never Ready) never takes capacity away from the old
ReplicaSet - the rollout simply stalls while the old version keeps serving, giving time to roll back.
Note: a rollback restores *config* too (ConfigMap is in the chart), but not data/schema migrations.

## Troubleshooting

| Symptom | Check |
|---|---|
| Pods `Pending` | `kubectl describe pod` - insufficient CPU/memory (requests 250m/256Mi each), or `topologySpread`/PSA rejection |
| `CreateContainerConfigError` | Secret `auth-api-secrets` missing or key name wrong: `kubectl -n auth-api get secret auth-api-secrets -o jsonpath='{.data}' \| jq 'keys'` |
| `ImagePullBackOff` | ECR repo/tag wrong or node role lacks ECR read: `kubectl describe pod`; `aws ecr describe-images --repository-name auth-api` |
| Pod restarting (`CrashLoopBackOff`) | `kubectl logs --previous`; startup probe too short? (budget = 10s + 30x5s) |
| Running but not Ready | `/health/ready` fails = DB/Redis unreachable. Usually the NetworkPolicy CIDRs or the RDS/ElastiCache security groups |
| `OOMKilled` | Raise `resources.limits.memory`; look at memory growth |
| HPA shows `<unknown>/70%` | metrics-server not installed or pods have no CPU request |
| 502/503 from ingress | No Ready endpoints: `kubectl -n auth-api get endpoints auth-api`; check ingress-nginx logs |
| 429 responses | Per-IP rate limit hit (`limit-rps`). Clients behind one NAT share a bucket - raise `ingress.rateLimit.rps` |
| CORS error in browser | Origin must exactly match `ingress.cors.allowOrigin` (scheme + host, no trailing slash) |
| Certificate not issued | `kubectl describe certificate,certificaterequest -n auth-api`; check issuer name/kind/group annotations and cert-manager logs |
| Node drain hangs | PDB working as intended (`minAvailable: 2`); needs >= 3 healthy pods, or scale up first |
| Can't reach RDS/Redis but SGs look right | CNI not enforcing/with wrong CIDRs, or egress rule missing - `kubectl describe netpol auth-api` |

## Assumptions

- The container listens on 3000, runs fine as UID 1000 with a read-only root filesystem (writes only to `/tmp`),
  reads `/app/config/config.json`, and has `sh` + `sleep` (used by `preStop`).
- ACM *public* certificates cannot be exported into a cluster, so "cert from ACM via cert-manager" is implemented with
  AWS Private CA (ACM PCA) through `aws-privateca-issuer`. The issuer is configurable (`ingress.certManager.*`), so a
  Let's Encrypt `ClusterIssuer` is a values-only change.
- The ingress controller is the standard `ingress-nginx` release (labels `app.kubernetes.io/name=ingress-nginx`).
- Replica count 3 is a *minimum*; the HPA owns scaling above it. Dev runs smaller (2 replicas, PDB 1) to save cost.
