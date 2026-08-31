# Deploying AuthSec on your own Kubernetes cluster

This guide installs AuthSec on a Kubernetes cluster you already run — EKS, AKS,
GKE, OpenShift, Rancher, kubeadm, k3s, anything conformant. Nothing here assumes
a particular distribution.

Plan for **45–60 minutes** for a first install.

If you would rather not run Kubernetes at all, see
[DEPLOY-DOCKER-COMPOSE.md](DEPLOY-DOCKER-COMPOSE.md) — one VM, one command.

---

## 1. What gets installed

| Component | Purpose | Chart |
|---|---|---|
| PostgreSQL | application + OAuth data | `postgresql/` (or bring your own) |
| HashiCorp Vault | secret storage | `vault/` |
| Ory Hydra | OAuth2 / OIDC provider | `hydra/` |
| Fluent Bit | log collection | `fluent-bit/` |
| AuthSec | API, web UI, log aggregator, SPIRE, MinIO | `authsec-charts/` |

Three hostnames are published; everything else stays inside the cluster.

| Hostname | Serves |
|---|---|
| `app.<your-domain>` | web UI |
| `api.<your-domain>` | AuthSec API |
| `oauth.<your-domain>` | OAuth2 / OIDC issuer |

---

## 2. Prerequisites

**Cluster**

- Kubernetes **1.24+**
- A **default StorageClass** that supports `ReadWriteOnce`
  (`kubectl get storageclass` — one must be marked `(default)`)
- Spare capacity: **4 vCPU / 8 GiB RAM** minimum, 8 vCPU / 16 GiB recommended
- **50 GiB** of persistent volume capacity

**Cluster add-ons** — if you already run these, use yours; do not install a second one.

- An **ingress controller**. Examples below use `ingressClassName: nginx`;
  substitute your own (`kubectl get ingressclass`).
- **cert-manager**, if you want automatic TLS. You can instead supply your own
  certificates as TLS secrets and skip it.

**Workstation**

- `kubectl` and `helm` 3.8+, pointed at the cluster (`kubectl get nodes` works)

**Access**

- Credentials for the AuthSec image registry (`docker-repo-public.authnull.com`)
- DNS you control, able to point the three hostnames at your ingress
- Outbound internet from the cluster, or a mirror of the images listed in §4

---

## 2b. Get the Helm charts

This repository contains the **guides and the Compose stack**. The Helm charts
are distributed separately, because they are versioned with the product.

Request them from AuthSec support, then extract them next to this guide so the
`./<chart>` paths below resolve:

```
authsec-deploy/
├── DEPLOY-KUBERNETES.md      <- you are here
├── postgresql/               <- from the chart bundle
├── vault/
├── hydra/
├── fluent-bit/
└── authsec-charts/
```

```bash
tar xzf authsec-charts-<version>.tar.gz
ls postgresql vault hydra fluent-bit authsec-charts   # all five present
```

The charts ship with placeholder credentials so they start out of the box.
§5 lists every one you must replace before the environment is real.

---

## 3. Decide your names up front

Every later step refers back to these. Namespaces and release names are yours to
pick; the defaults below match the reference deployment.

```bash
export DOMAIN=example.com

export NS_DB=database-prod       REL_DB=postgresql
export NS_VAULT=vault-prod       REL_VAULT=vault
export NS_HYDRA=hydra-prod       REL_HYDRA=hydra
export NS_LOG=fluent-prod        REL_LOG=fluent-bit
export NS_APP=authsec-prod       REL_APP=prod

kubectl create namespace $NS_DB
kubectl create namespace $NS_VAULT
kubectl create namespace $NS_HYDRA
kubectl create namespace $NS_LOG
kubectl create namespace $NS_APP
```

> **The names decide in-cluster DNS.** A Helm release `postgresql` in namespace
> `database-prod` is reachable at `postgresql-primary.database-prod.svc.cluster.local`.
> If you change a name, every reference to that host in the values files must
> change with it. §6 lists exactly which.

---

## 4. Registry access

The application images are private:

```
docker-repo-public.authnull.com/authsec:production
docker-repo-public.authnull.com/ui:production
docker-repo-public.authnull.com/log-aggregator:production
docker-repo-public.authnull.com/spire-headless:production
docker-repo-public.authnull.com/log-agent:production
```

The chart ships a pull secret named `<release>-docker-registry-secret`. If your
account uses different credentials, replace it:

```bash
kubectl -n $NS_APP create secret docker-registry ${REL_APP}-docker-registry-secret \
  --docker-server=docker-repo-public.authnull.com \
  --docker-username=<your-user> \
  --docker-password=<your-password> \
  --dry-run=client -o yaml | kubectl apply -f -
```

Confirm the cluster can reach the registry before going further — an
IP-allowlisted registry is the single most common cause of a stalled install:

```bash
kubectl run reg-test --rm -it --restart=Never --image=busybox:1.36 -- \
  wget -qS --spider https://docker-repo-public.authnull.com/v2/ 2>&1 | head -3
```

Also required from inside the cluster: `quay.io` (MinIO), `docker.io` (Postgres,
Fluent Bit), `hashicorp` images (Vault).

---

## 5. Replace every default secret

**Do this before installing.** The charts ship working placeholder values so the
stack starts out of the box. They are public knowledge and must not survive into
your environment.

```bash
openssl rand -hex 32      # JWT and HMAC secrets
openssl rand -base64 32   # encryption keys
```

| File | Key | Used for |
|---|---|---|
| `postgresql/values.yaml` | `auth.password`, `auth.postgresPassword` | database login |
| `authsec-charts/values.yaml` | `authsec.env.jwtSecret`, `jwtDefSecret`, `jwtSdkSecret` | API tokens |
| | `authsec.env.totpEncryptionKey` | TOTP seeds at rest |
| | `encryption.key` | SPIRE data at rest |
| | `minio.rootPassword` | object storage |
| `hydra/values.yaml` | `secrets.secretsSystem`, `secretsCookie` | OAuth token signing |
| `vault/values.yaml` | `server.vaultInit.password` | Vault userpass login |

Rotating `secretsSystem` later invalidates every issued OAuth token, and
`encryption.key` cannot be rotated without re-encrypting existing data. Set them
correctly now.

---

## 6. Make the endpoints agree

Four values must name the services you created in §3. This is the most common
cause of a deployment that installs cleanly but does not work.

| File | Key | Value |
|---|---|---|
| `authsec-charts/values.yaml` | `postgresDb.dbHost` | `postgresql-primary.database-prod.svc.cluster.local` |
| | `authsec.env.vaultAddr`, `spireheadless.env.vault_addr` | `http://vault.vault-prod.svc.cluster.local:8200` |
| | `authsec.env.hydraAdminUrl` | `http://hydra-admin.hydra-prod.svc.cluster.local:4445` |
| `hydra/values.yaml` | `secrets.dsn` (base64) | `postgres://<user>:<pass>@postgresql-primary.database-prod.svc.cluster.local:5432/hydra?sslmode=disable` |

Hydra's DSN is base64-encoded. Generate it with:

```bash
echo -n 'postgres://authsec:PASSWORD@postgresql-primary.database-prod.svc.cluster.local:5432/hydra?sslmode=disable' | base64 -w0
```

The same URL, un-encoded, also appears on the `dsn:` line in
`hydra/templates/configmap.yaml`. Update both.

Hostnames appear in `authsec-charts/templates/ingress.yaml`,
`hydra/templates/ingress.yaml` and several `authsec.env.*` URLs — replace
`authsec.ai` with your domain throughout.

### Using your own PostgreSQL (RDS, Cloud SQL, existing cluster)

Skip §7 entirely. Point `postgresDb.dbHost` and Hydra's DSN at your server, then
create the two databases yourself:

```sql
CREATE ROLE authsec LOGIN PASSWORD '...';
CREATE DATABASE authsec OWNER authsec;
CREATE DATABASE hydra   OWNER authsec;
\c hydra
ALTER SCHEMA public OWNER TO authsec;
GRANT ALL ON SCHEMA public TO authsec;
```

The last two lines matter on **PostgreSQL 15 and newer**, which revoke `CREATE`
on `public` from ordinary roles. Without them Hydra's migration fails with a
permission error.

---

## 7. PostgreSQL

```bash
helm upgrade --install $REL_DB ./postgresql -n $NS_DB \
  -f postgresql/values.yaml --timeout 10m

kubectl -n $NS_DB rollout status statefulset/${REL_DB}-primary
```

Then create Hydra's database (the chart only creates the application one):

```bash
PGPASS=$(kubectl -n $NS_DB get secret $REL_DB -o jsonpath='{.data.postgres-password}' | base64 -d)

kubectl -n $NS_DB exec -i ${REL_DB}-primary-0 -c postgresql -- \
  env PGPASSWORD="$PGPASS" psql -U postgres -h 127.0.0.1 <<'SQL'
SELECT 'CREATE DATABASE hydra' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='hydra')\gexec
SQL

kubectl -n $NS_DB exec -i ${REL_DB}-primary-0 -c postgresql -- \
  env PGPASSWORD="$PGPASS" psql -U postgres -h 127.0.0.1 -d hydra <<'SQL'
ALTER DATABASE hydra OWNER TO authsec;
ALTER SCHEMA public OWNER TO authsec;
GRANT ALL ON SCHEMA public TO authsec;
SQL
```

Replace `authsec` with whatever `auth.username` you set.

> ### If you enable the read replica
> `architecture: replication` starts a standby, and the chart has a defect there:
> `primary.extendedConfiguration` sets `max_connections = 1000`, but a read
> replica never receives a `postgresql.conf` containing `include_dir = 'conf.d'`,
> so that setting is ignored. The standby starts with the built-in
> `max_connections = 100`, and PostgreSQL refuses to run a standby configured
> lower than its primary:
>
> ```
> FATAL: recovery aborted because of insufficient parameter settings
> DETAIL: max_connections = 100 is a lower setting than on the primary server
> ```
>
> The replica then crash-loops forever. Either run
> `architecture: standalone`, or give the replica the primary's config:
>
> ```bash
> kubectl -n $NS_DB create configmap pg-read-config \
>   --from-file=postgresql.conf=<(sed -n '/^  configuration: |/,/^  [a-z]/p' postgresql/values.yaml \
>                                 | sed '1d;$d;s/^    //')
> ```
> then add to your values:
> ```yaml
> readReplicas:
>   extraVolumes:
>     - name: read-config
>       configMap: { name: pg-read-config }
>   extraVolumeMounts:
>     - name: read-config
>       mountPath: /bitnami/postgresql/conf/postgresql.conf
>       subPath: postgresql.conf
> ```

---

## 8. Vault

```bash
helm upgrade --install $REL_VAULT ./vault -n $NS_VAULT \
  -f vault/values.yaml \
  --set "server.vaultInit.syncNamespaces={$NS_APP}" \
  --timeout 10m
```

The chart initialises Vault, stores the unseal key and root token in
`<release>-init-keys`, and runs a sidecar that re-unseals it after restarts. Its
init job needs outbound internet (it installs `kubectl` and `jq` at runtime).

`syncNamespaces` copies the generated `<release>-credentials` secret into your
application namespace, which is where the AuthSec pods read their Vault token.

```bash
kubectl -n $NS_VAULT exec ${REL_VAULT}-0 -c vault -- vault status | grep Sealed   # expect: false
kubectl -n $NS_APP get secret ${REL_VAULT}-credentials
```

> **Back up the unseal key now.** It exists only inside the cluster:
> ```bash
> kubectl -n $NS_VAULT get secret ${REL_VAULT}-init-keys -o yaml > vault-keys-BACKUP.yaml
> ```
> Store it somewhere safe and delete the local copy. Losing it makes Vault's
> contents unrecoverable.

---

## 9. Ory Hydra

```bash
helm upgrade --install $REL_HYDRA ./hydra -n $NS_HYDRA \
  -f hydra/values.yaml --timeout 10m

kubectl -n $NS_HYDRA wait --for=condition=complete job/hydra-migrate-job --timeout=300s
kubectl -n $NS_HYDRA rollout status deployment/hydra
```

Hydra crash-loops until the migration job finishes; that is expected.

> The migration job is a plain `Job`, not a Helm hook, and Jobs are immutable.
> Before any re-install or upgrade:
> ```bash
> kubectl -n $NS_HYDRA delete job hydra-migrate-job --ignore-not-found
> ```
> Otherwise Helm fails with a field-is-immutable error.

If the job fails, it is almost always the DSN — check it points at the Postgres
service from §6 and that the role owns the `hydra` database.

---

## 10. Fluent Bit

```bash
helm upgrade --install $REL_LOG ./fluent-bit -n $NS_LOG \
  -f fluent-bit/values.yaml --timeout 5m
```

Set `metrics.serviceMonitor.enabled: false` unless you run the Prometheus
Operator — the chart otherwise emits a `ServiceMonitor` and Helm fails with
`no matches for kind "ServiceMonitor"`.

The log aggregator reaches it at `<release>.<namespace>.svc.cluster.local:2020`;
confirm `logaggregator`'s `FLUENT_BIT_URL` matches.

---

## 11. AuthSec

```bash
helm upgrade --install $REL_APP ./authsec-charts -n $NS_APP \
  -f authsec-charts/values.yaml --timeout 10m

kubectl -n $NS_APP get pods
```

Enable only what you need — each component has an `enabled` flag in
`values.yaml`. The core set is `authsec`, `ui`, `logaggregator`, `spireheadless`
and `minio`.

---

## 12. Ingress and TLS

The charts create Ingress objects annotated for cert-manager. Point them at your
ingress class and issuer.

**DNS-01** (needed for wildcard certificates; requires a supported DNS provider):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef: { name: cloudflare-api-token, key: api-token }
```

**HTTP-01** — simpler, works with any DNS provider, but cannot issue wildcards
and requires the hostnames to already resolve to your ingress:

```yaml
    solvers:
      - http01:
          ingress:
            class: nginx
```

Then point DNS at the ingress:

```bash
kubectl -n <ingress-namespace> get svc   # take the EXTERNAL-IP
```

| Record | Type | Value |
|---|---|---|
| `app.<domain>` | A | ingress external IP |
| `api.<domain>` | A | ingress external IP |
| `oauth.<domain>` | A | ingress external IP |

Watch issuance:

```bash
kubectl get certificate -A
kubectl -n cert-manager logs deploy/cert-manager -f
```

> Hydra's chart also publishes an **admin** hostname. That API creates and
> deletes OAuth clients with no authentication of its own. Either remove that
> rule from `hydra/templates/ingress.yaml` and reach it with `kubectl
> port-forward svc/hydra-admin 4445:4445`, or put an authenticating proxy or
> IP allow-list in front of it. Do not expose it as shipped.

---

## 13. Verify

```bash
kubectl get pods -A | grep -Ev 'Running|Completed'   # expect no output
kubectl get certificate -A                            # READY=True
curl -sS https://oauth.$DOMAIN/.well-known/openid-configuration | head -20
curl -sSI https://app.$DOMAIN | head -1
```

Checklist:

- [ ] every pod Running or Completed
- [ ] `kubectl -n $NS_VAULT exec $REL_VAULT-0 -c vault -- vault status` shows `Sealed false`
- [ ] `hydra-migrate-job` shows Complete
- [ ] all certificates READY
- [ ] OIDC discovery returns your `oauth.<domain>` issuer
- [ ] Vault unseal key backed up outside the cluster
- [ ] every placeholder secret from §5 replaced

---

## 14. Day-2

**Upgrade** — bump image tags in `values.yaml`, then:

```bash
kubectl -n $NS_HYDRA delete job hydra-migrate-job --ignore-not-found
helm upgrade $REL_APP ./authsec-charts -n $NS_APP -f authsec-charts/values.yaml
```

**Back up** — nightly at minimum:

```bash
kubectl -n $NS_DB exec ${REL_DB}-primary-0 -c postgresql -- \
  env PGPASSWORD="$PGPASS" pg_dumpall -U postgres > authsec-$(date +%F).sql
```

Also back up the Vault unseal key (§8) and the MinIO volume.

**Remove**

```bash
helm uninstall $REL_APP -n $NS_APP
helm uninstall $REL_HYDRA -n $NS_HYDRA
helm uninstall $REL_LOG -n $NS_LOG
helm uninstall $REL_VAULT -n $NS_VAULT
helm uninstall $REL_DB -n $NS_DB
kubectl delete namespace $NS_APP $NS_HYDRA $NS_LOG $NS_VAULT $NS_DB
```

Namespace deletion destroys the PersistentVolumeClaims and all data.

---

## 15. Troubleshooting

| Symptom | Cause |
|---|---|
| `ImagePullBackOff` | registry unreachable or pull secret wrong (§4) |
| PVC stuck `Pending` | no default StorageClass, or no capacity |
| `hydra-migrate-job` fails | DSN wrong, or the role does not own the `hydra` database (§6) |
| Hydra `CrashLoopBackOff` | normal until the migration completes |
| Read replica crash-loops | `max_connections` mismatch (§7) |
| Certificate stuck `False` | `kubectl describe certificate`; DNS-01 needs API credentials, HTTP-01 needs the hostname to resolve already |
| Vault pods `0/1` | Vault reports NotReady while sealed — check the init job's logs |
| App starts but cannot log in | an endpoint in §6 points at a service that does not exist |

Useful:

```bash
kubectl -n <ns> describe pod <pod>
kubectl -n <ns> logs <pod> --all-containers --tail=100
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

---

## Support

Include with any request: `kubectl version`, `helm list -A`, `kubectl get pods -A`,
and the logs of the failing pod. Never send secrets, values files containing
passwords, or Vault keys.
