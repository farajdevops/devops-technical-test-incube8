# Submission - DevOps Engineer Technical Test (Incube8)

| | |
|---|---|
| **Name** | `MOHAMED JASSIM FARAJ` |
| **Contact** | `jassimfaraj.tech@gmail.com` / `+919489118981` |
| **Test selected** | **Option C - Kubernetes Manifests + Helm Chart** (`test-c-kubernetes-helm/`) |
| **Time taken** | `55 minutes` |
| **GitHub repository** | `https://github.com/farajdevops` |

## What was delivered

- `test-c-kubernetes-helm/k8s/` - plain manifests: Namespace, ServiceAccount, ConfigMap, Deployment, Service,
  Ingress, HPA, PDB, NetworkPolicy (+ `examples/secret.example.yaml`, placeholder-only Secret template)
- `test-c-kubernetes-helm/helm/auth-api/` - Helm chart with fully templated objects and
  `values-dev.yaml`, `values-staging.yaml`, `values-prod.yaml`
- `test-c-kubernetes-helm/README.md` - architecture, prerequisites, kubectl + Helm deploy per environment,
  testing, rollback, troubleshooting

## Assumptions

- The app listens on port 3000, runs as non-root (UID 1000) with a read-only root filesystem, and reads its JSON
  config from `/app/config/config.json`. The image contains `sh`/`sleep` (used for the `preStop` hook).
- AWS ACM public certificates are not exportable, so "cert from ACM via cert-manager" is done with the
  `aws-privateca-issuer` plugin (`AWSPCAClusterIssuer`). The issuer name/kind/group are values, so switching to
  Let's Encrypt is a configuration change.
- Standard `ingress-nginx` and `metrics-server` are installed; the VPC CNI (or Calico/Cilium) enforces NetworkPolicy.
- RDS / ElastiCache CIDRs (`10.x.20.0/24`, `10.x.30.0/24`) and the image account ID are placeholders from the brief.
- Secrets are never in git. Staging/prod reference a pre-created Secret; only dev lets the chart create a placeholder one.

## Validation performed (and not performed)

- All 9 manifests in `k8s/` pass `kubernetes-validate --strict` against the **Kubernetes 1.28** schemas.
- All YAML (manifests + values files) parses cleanly; resource names, labels and selectors were cross-checked by hand.
- **Not done:** `helm lint` / `helm template` / `kubectl apply --dry-run=server`. Helm and cluster access were not
  available in the environment I worked in (downloads blocked, no cluster), so the Helm templates have been
  reviewed by hand but **not rendered**. Run `helm lint` and `helm template` first (commands in the README).

## Known limitations / what I would do with more time

- Render and test the chart in CI (`helm lint`, `helm template | kubeconform`, `kind` cluster smoke test, `chart-testing`).
- Replace the dev-only chart-managed Secret and the kubectl-created secret with External Secrets Operator + AWS Secrets Manager.
- Add Prometheus `ServiceMonitor`, alerts (restart rate, 5xx, HPA at max) and a Grafana dashboard.
- Image pinned by digest, signature verification (cosign) and admission policy (Kyverno/Gatekeeper).
- Use `topologySpreadConstraints: DoNotSchedule` in prod once node capacity per AZ is confirmed.
- Add `values.schema.json` so bad values fail at `helm lint` time; Kustomize overlays as an alternative to Helm.

## AI tools disclosure

I used **Claude (Anthropic, via Claude Code)** to help produce this submission: it drafted the manifests, the Helm
templates/values and the README from the task brief, and ran the schema validation. I reviewed the output and can
explain every resource and design choice (e.g. why `maxUnavailable: 0` + `preStop` gives zero-downtime rollouts, why the
HPA owns `replicas`, why egress is default-deny with explicit RDS/Redis/DNS rules, and why ACM public certs can't be used
directly with cert-manager).
