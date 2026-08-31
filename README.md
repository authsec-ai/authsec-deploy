# Deploying AuthSec

Two supported ways to run AuthSec on your own infrastructure.

| | [Kubernetes](DEPLOY-KUBERNETES.md) | [Docker Compose](DEPLOY-DOCKER-COMPOSE.md) |
|---|---|---|
| **Use when** | you already run a cluster | you want one VM |
| Setup time | 45–60 min | 20–30 min |
| High availability | yes, if your cluster is | no — single host |
| Horizontal scaling | yes | no |
| Rolling upgrades | yes | brief restart |
| Needs | K8s 1.24+, ingress controller, StorageClass | Docker 24+, ports 80/443 |
| TLS | cert-manager, or your own certificates | automatic, via Caddy |

Both deploy the same product: the AuthSec API and UI, Ory Hydra for OAuth2/OIDC,
PostgreSQL, HashiCorp Vault, a log pipeline and object storage.

## What you need either way

- A domain, with three records pointing at your deployment:
  `app.<domain>`, `api.<domain>`, `oauth.<domain>`
- Credentials for the AuthSec image registry
- The Helm charts (Kubernetes only) — see §2b of that guide

## Before you go live

Both guides ship with **placeholder secrets** so the stack starts immediately.
They are published values and are not secret. Replace every one of them —
each guide has a checklist — and confirm:

```bash
grep -c CHANGE_ME docker-compose/.env    # must be 0
```

## Contents

```
DEPLOY-KUBERNETES.md          existing-cluster guide
DEPLOY-DOCKER-COMPOSE.md      single-VM guide
docker-compose/               the Compose stack
  docker-compose.yml          11 services; only Caddy publishes ports
  .env.example                copy to .env and fill in
  Caddyfile                   TLS and routing
  vault-init.sh               initialise and unseal Vault
  initdb/                     database bootstrap, runs once
  fluent-bit/                 log collector configuration
scripts/check-no-secrets.sh   pre-publish safety check
```

## Support

Include your platform, versions, and the failing component's logs. Never send
`.env`, `vault-keys.txt`, values files containing passwords, or Vault keys.
