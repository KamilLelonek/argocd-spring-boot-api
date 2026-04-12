# spring-boot-api GitOps

ArgoCD ApplicationSet + Helm chart deploying the Spring Boot API to two Kubernetes clusters
(dev/prd). Secrets pulled from AWS Secrets Manager via External Secrets Operator. TLS via
cert-manager + Let's Encrypt.

---

## Repository Structure

```
spring-boot-api/
├── argocd/
│   ├── applicationset.yaml       # Deploys the app to both clusters
│   ├── cluster-secret-store.yaml # Tells ESO how to connect to AWS Secrets Manager
│   └── cluster-issuers.yaml      # Tells cert-manager how to issue TLS certs (Let's Encrypt)
├── helm-chart/
│   └── spring-boot-api/
│       ├── Chart.yaml
│       ├── values.yaml           # Shared defaults (all envs inherit these)
│       └── templates/
│           ├── _helpers.tpl         # Shared name/label helpers
│           ├── configmap.yaml       # app config.json mounted as a file
│           ├── externalsecret.yaml  # Pulls secrets from AWS SM into a K8s Secret
│           ├── deployment.yaml      # Pods: rolling update, probes, security, graceful shutdown
│           ├── service.yaml         # ClusterIP, 3 ports (api/logs/soap)
│           ├── ingress.yaml         # nginx ingress, TLS, 3 path routes
│           └── pdb.yaml             # Minimum pods guaranteed during node drains
└── environments/
    ├── dev/values.yaml           # Dev: 3 replicas, staging TLS, dev SM secret path
    └── prd/values.yaml           # Prd: 5 replicas, prod TLS, prd SM secret path
```

**Separation of concerns**: `helm-chart/` is how to run the app (owned by platform team).
`environments/` is what each environment looks like (owned by app team).
Different teams, different review gates, same repository.

---

## Prerequisites

Both clusters are provisioned and configured by `terraform/`. Before applying the
ApplicationSet, the following must be true on each cluster:

- nginx ingress, cert-manager, ESO, and ArgoCD are installed
- `argocd/cluster-secret-store.yaml` is applied (configures ESO to read AWS SM)
- `argocd/cluster-issuers.yaml` is applied (configures cert-manager Let's Encrypt issuers)
- AWS SM secrets at `/spring-boot-api/dev/credentials` and `/spring-boot-api/prd/credentials`
  are populated with real values

Both clusters must be registered in the central ArgoCD instance. Terraform outputs the
exact command; the `--name` must match `clusterName` in `applicationset.yaml`:

```bash
argocd cluster add <context-name> --name dev-global-cluster-0
argocd cluster add <context-name> --name prd-global-cluster-5
```

---

## Deploy

```bash
kubectl apply -f argocd/applicationset.yaml -n argocd
```

ArgoCD creates one Application per cluster and syncs automatically. Watch progress:

```bash
argocd app list
argocd app get spring-boot-api-dev
argocd app get spring-boot-api-prd
```

---

## How It Works

### ArgoCD ApplicationSet (List Generator)

One ApplicationSet creates two Applications, one per cluster:

```yaml
generators:
  - list:
      elements:
        - env: dev
          clusterName: dev-global-cluster-0   # matches --name from argocd cluster add
          chartRevision: HEAD                 # dev tracks latest chart commit
        - env: prd
          clusterName: prd-global-cluster-5
          chartRevision: v1.0.0               # prd pinned to a tag (explicit promotion)

destination:
  name: "{{ .clusterName }}"   # references cluster by registered ArgoCD name, not URL
  namespace: spring-boot-api
```

**List Generator**: Explicit, auditable. You see exactly which clusters exist and what
revision each runs. The alternative (Cluster Generator) auto-discovers clusters by label.

**Pinning prd to a tag**: With `HEAD`, any chart commit would reach prod immediately.
A tag means prod only changes when someone bumps the tag in a PR -- deliberate promotion,
no accidental rollouts.

### Multi-Source (values outside the chart directory)

```yaml
sources:
  - path: helm-chart/spring-boot-api
    targetRevision: "{{ .chartRevision }}"   # chart at tag or HEAD
    helm:
      valueFiles:
        - $values/environments/{{ .env }}/values.yaml
  - ref: values                              # second source acts as $values
    targetRevision: HEAD                     # env values always at HEAD
```

`$values` is an ArgoCD 2.6+ feature. Without it, values files must live inside the chart
directory. With it, `helm-chart/` and `environments/` are fully independent -- separate
ownership, separate review gates. Values always come from HEAD so config changes (replicas,
hosts) deploy without requiring a chart version bump.

### Secret Management (ESO + AWS Secrets Manager)

Secrets are never stored in Git. The flow:

```
AWS Secrets Manager
  /spring-boot-api/{env}/credentials
  { "APP_SECRET_KEY": "...", "DB_PASSWORD": "...", "JWT_SECRET": "..." }
          |
          | ESO polls every 1h (or on-demand annotate)
          v
  K8s Secret (same name as the app)
          |
          | envFrom.secretRef
          v
  Pod environment variables
```

1. `ClusterSecretStore` (`argocd/cluster-secret-store.yaml`): configures ESO to authenticate
   via IRSA and connect to AWS SM in eu-central-1. Cluster-level, managed by the platform team.
2. `ExternalSecret` (`templates/externalsecret.yaml`): per-app declaration of which secret
   to pull and what K8s Secret to create from it. `dataFrom.extract` pulls the entire JSON
   object -- no need to enumerate individual keys.
3. `Deployment` reads the resulting K8s Secret via `envFrom.secretRef`.

**IRSA** (IAM Roles for Service Accounts): EKS mechanism to give a pod AWS permissions
without storing access keys. The cluster's OIDC endpoint is registered in IAM. When ESO
starts, EKS validates its ServiceAccount JWT and exchanges it for temporary AWS credentials.
No long-lived credentials stored anywhere.

**Sync wave ordering**: ExternalSecret is wave `0`, Deployment is wave `1`. ArgoCD waits
for the ExternalSecret to reach Healthy status (= the K8s Secret has been written by ESO)
before applying the Deployment. Without this ordering, pods fail with
`CreateContainerConfigError` because the Secret they reference does not exist yet.

**Secret rotation**: Update the value in AWS SM. ESO syncs the K8s Secret within
`refreshInterval` (1 hour). Running pods do NOT pick up new env vars automatically;
environment variables are snapshotted at pod start. After ESO syncs, trigger a rollout:
```bash
# 1. Force immediate ESO sync (optional, otherwise waits up to 1h)
kubectl annotate externalsecret spring-boot-api -n spring-boot-api \
  force-sync=$(date +%s) --overwrite

# 2. Restart pods to pick up the new Secret values
kubectl rollout restart deployment/spring-boot-api -n spring-boot-api
```

### TLS (cert-manager + Let's Encrypt)

```
Ingress annotation: cert-manager.io/cluster-issuer: letsencrypt-staging
  --> cert-manager creates a CertificateRequest
  --> Let's Encrypt sends HTTP-01 challenge to /.well-known/acme-challenge/<token>
  --> cert-manager serves the challenge response via a temporary Ingress
  --> Let's Encrypt verifies ownership and issues the certificate
  --> cert-manager writes the cert+key into spec.tls[].secretName
  --> nginx-ingress reads that Secret for HTTPS termination
  --> cert-manager renews automatically before expiry
```

**Staging vs prod issuer**:
- `letsencrypt-staging`: untrusted cert (browser shows warning), ~3000x higher rate limits.
  Use for dev and when iterating on TLS config to avoid hitting prod limits.
- `letsencrypt-prod`: browser-trusted. Rate-limited to 50 certs/week per domain.
  Switch to this only after staging works end-to-end.

**HTTP-01 requirement**: The domain must be publicly resolvable and port 80 must be reachable
by Let's Encrypt servers. Private/internal domains require the DNS-01 solver instead.
See the DNS section below.

### Rolling Updates (Zero Downtime)

```yaml
rollingUpdate:
  maxUnavailable: 0   # never terminate an old pod before its replacement is Ready
  maxSurge: 1         # allow one extra pod during the rollout
```

Kubernetes default is 25% `maxUnavailable`, floored. With prd's 5 replicas:
`floor(5 * 0.25) = 1`, allowing one pod to be terminated before its replacement is Ready.
Explicit `0` is safe regardless of replica count.

`maxSurge: 1` is required: `maxUnavailable: 0` + `maxSurge: 0` deadlocks -- the rollout
cannot add a pod (no surge) and cannot remove a pod (none available to spare).

### Graceful Shutdown

When Kubernetes deletes a pod, two things happen simultaneously:
- The container receives SIGTERM
- The pod is removed from Service endpoints (no new traffic)

Endpoint removal takes a few seconds to propagate through kube-proxy. Without a delay,
SIGTERM fires before propagation completes and in-flight requests land on a terminating pod.

```yaml
preStop:
  exec:
    command: ["sleep 5 && wget -q -O- http://localhost:8080/service/shutdown || true"]
```

`sleep 5` covers the propagation lag. The shutdown endpoint then triggers Spring Boot's
graceful shutdown (drains active requests). `|| true` prevents a non-zero exit from blocking
termination for the full `terminationGracePeriodSeconds` (60s).

### Probes

Three probe types work together:

- **startupProbe**: runs during startup only. Liveness and readiness are paused until it
  passes. Budget: `failureThreshold: 30 * periodSeconds: 10 = 5 minutes`. Handles slow
  Spring Boot starts (DB migrations, heavy initialization) without `initialDelaySeconds`
  guesswork. Once it passes, it never runs again.
- **livenessProbe**: "is the process alive?" Failure restarts the container.
- **readinessProbe**: "should this pod receive traffic?" Failure removes it from Service
  endpoints without restarting. Pod keeps running but receives no requests.

Because startupProbe handles the startup window, liveness and readiness need no
`initialDelaySeconds` -- they activate immediately after startupProbe succeeds.

### Security

**Pod-level** (applies to all containers):
- `runAsNonRoot: true` -- rejects images that run as UID 0.
- `runAsUser: 1000` -- explicit UID, does not rely on image default.
- `seccompProfile: RuntimeDefault` -- enables the container runtime's default syscall
  filter, blocking ~100 dangerous syscalls. Requires K8s >= 1.22.

**Container-level**:
- `readOnlyRootFilesystem: true` -- the container cannot write anywhere except explicitly
  mounted volumes. Spring Boot needs `/tmp` for Tomcat work files, so an `emptyDir` is
  mounted there.
- `allowPrivilegeEscalation: false` -- prevents setuid/setgid privilege escalation.
- `capabilities.drop: ["ALL"]` -- removes all Linux capabilities. A plain HTTP server
  needs none of them.

### High Availability

**Replicas**: 3 in dev, 5 in prd.

**topologySpreadConstraints**: distributes pods across nodes so a single node failure
loses at most one or two pods. `maxSkew: 1` = at most 1 pod difference between any two
nodes. `DoNotSchedule` blocks new pods if the constraint cannot be met -- switch to
`ScheduleAnyway` in clusters with fewer nodes than replicas.

**PodDisruptionBudget** (`policy/v1`): guarantees minimum 1 pod stays Running during
voluntary disruptions (node drains, cluster upgrades).

The critical detail: Deployment's `maxUnavailable: 0` only governs rollouts triggered
by the Deployment controller. Node evictions use the Eviction API directly against the
ReplicaSet, bypassing the Deployment strategy entirely. Without a PDB, all pods can be
evicted simultaneously during a `kubectl drain`, regardless of `maxUnavailable`.

`policy/v1` requires K8s >= 1.21. `policy/v1beta1` was removed in K8s 1.25.

---

## Assumptions

| Decision | Choice | Reason |
|----------|--------|--------|
| Image | `busybox:stable` | Per task spec. Replace with the actual Spring Boot image. |
| Image pull policy | `Always` | Mutable tag `stable` requires a fresh registry check on every pod start. Use `IfNotPresent` only with immutable tags (SHA digests). |
| ArgoCD generator | List | Explicit, auditable. Cluster Generator auto-discovers by label. |
| Chart revision (dev) | HEAD | Fast feedback: chart changes reach dev immediately. |
| Chart revision (prd) | tag pin | No accidental rollouts. Prod changes on explicit version bump. |
| Values revision | HEAD | Config changes (replicas, hosts) deploy without a chart version bump. |
| Namespace | `spring-boot-api` | Created automatically by ArgoCD `CreateNamespace=true`. |
| ArgoCD project | `spring-boot` | Logical grouping. Created by Terraform (`kubectl_manifest.argocd_project`). |
| Ingress class | `nginx` | Standard. Change via `ingress.className` value. |
| Secret storage | AWS Secrets Manager | No secrets in Git. IRSA for keyless auth. ESO for sync. |
| TLS issuer (dev) | letsencrypt-staging | High rate limits. Safe for iteration. Cert is browser-untrusted. |
| TLS issuer (prd) | letsencrypt-prod | Browser-trusted. Rate limited. Use after staging validates. |
| PDB minAvailable | 1 | Always keep at least 1 pod alive during voluntary disruptions. |

---

## DNS

cert-manager's HTTP-01 challenge requires the app hostnames to be publicly resolvable and
port 80 reachable by Let's Encrypt servers before TLS issuance works. Create DNS A records
pointing to the nginx ingress LoadBalancer IP (available in Terraform output) before deploying:

- `api.dev.inpost.pl` -> ingress LoadBalancer (dev cluster)
- `api.prd.inpost.pl` -> ingress LoadBalancer (prd cluster)

---

## Local Chart Testing

```bash
# Render templates without deploying
helm template dev helm-chart/spring-boot-api -f environments/dev/values.yaml
helm template prd helm-chart/spring-boot-api -f environments/prd/values.yaml

# Lint for errors
helm lint helm-chart/spring-boot-api -f environments/dev/values.yaml
```
