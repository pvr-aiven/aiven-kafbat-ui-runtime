# Kafbat UI on Aiven Runtime

Deploy [Kafbat UI](https://github.com/kafbat/kafka-ui) on **Aiven Runtime**, connected
to an **existing Aiven for Apache Kafka service** over `SASL_SSL` /
`SCRAM-SHA-512`, with the **Karapace Schema Registry**.

## Contents

| File | Purpose |
| --- | --- |
| `Dockerfile` | Official Kafbat UI image plus an Aiven-aware entrypoint |
| `entrypoint.sh` | Builds the truststore from the project CA, assembles the SASL/SCRAM and Schema Registry config |
| `compose.yaml` | Manifest scanned by Aiven Runtime |
| `compose.dev.yaml` | Local run against the real Aiven service |
| `.env.example` | Variables to fill in for the local run |
| `scripts/aiven-env.sh` | Generates `.env` + `certs/ca.pem` through `avn` (read-only) |

## Why an entrypoint rather than plain variables

Two things get in the way of a purely declarative config:

1. **The CA is private.** Aiven service certificates are signed by the project CA,
   which is not in the JVM truststore. Without importing it, `SASL_SSL` fails and
   so do the HTTPS calls to Karapace. The entrypoint copies the JVM `cacerts`,
   adds the Aiven CA to the copy, and points both the Kafka client and the JVM's
   HTTP clients at it.
2. **The Runtime integration exposes mTLS, not SCRAM.** It provides
   `KAFKA_BOOTSTRAP_SERVERS`, `KAFKA_SECURITY_PROTOCOL=SSL`, `KAFKA_ACCESS_KEY`,
   `KAFKA_ACCESS_CERT` and `KAFKA_CA_CERT`. SCRAM needs a username and password
   supplied separately — and **the right port** (see below).

The entrypoint handles both modes: if it finds `KAFKA_SASL_USERNAME` /
`KAFKA_SASL_PASSWORD` it configures SASL_SSL; otherwise, if client certificates
are present, it falls back to mTLS.

## ⚠️ The port trap

Aiven exposes Kafka on **two different ports**: one for mTLS, one for SASL. The
Runtime integration hands you the **mTLS** one. If `KAFKA_BOOTSTRAP_SERVERS` is
not overridden, the SASL connection fails with an unhelpful timeout.

The SASL port is in Console → Kafka service → *Overview* → *Connection
information* → **SASL** tab. The SASL method has to be enabled on the service
first:

```bash
avn service update SERVICE --project PROJECT -c kafka_authentication_methods.sasl=true
```

## 1. Run it locally first

```bash
./scripts/aiven-env.sh my-project my-kafka-service   # or: cp .env.example .env
docker compose -f compose.dev.yaml up --build
open http://localhost:8080
```

If the UI lists your topics locally, the same config will work on Runtime.

## 2. Deploy to Aiven Runtime

Runtime deploys from GitHub, and **Compose files only work through the Console** —
the API and the MCP server accept Dockerfiles/Containerfiles only.

```bash
git init && git add . && git commit -m "Kafbat UI for Aiven Runtime"
git remote add origin git@github.com:<org>/kafbat-ui-aiven-runtime.git
git push -u origin main
```

Then, in the Console:

1. Project → **Runtime** → **Deploy application**
2. Select your GitHub account, repository and branch
3. Pick `compose.yaml` → **Scan**
4. On the detected Kafka service: **Swap with an existing service** → select your
   existing Kafka service → **Apply**
5. **Configure**: add the variables and secrets from the table below
6. **Deploy**

### Variables and secrets to set

| Key | Type | Value |
| --- | --- | --- |
| `KAFKA_BOOTSTRAP_SERVERS` | variable | `host:SASL_PORT` (overrides the integration) |
| `KAFKA_SASL_USERNAME` | variable | `avnadmin`, or a dedicated user |
| `KAFKA_SASL_PASSWORD` | **secret** | that user's password |
| `KAFKA_SASL_MECHANISM` | variable | `SCRAM-SHA-512` |
| `SCHEMA_REGISTRY_URL` | variable | Karapace URI (`https://…`) |
| `SCHEMA_REGISTRY_USER` | variable | `avnadmin` |
| `SCHEMA_REGISTRY_PASSWORD` | **secret** | Karapace password |
| `KAFKA_CLUSTER_NAME` | variable | Display name in the UI |
| `KAFKA_CLUSTERS_0_READONLY` | variable | `true` while the UI is unprotected |

`KAFKA_CA_CERT` is injected by the integration, so there is nothing to do. Without
an integration, supply the project CA in an `AIVEN_CA_CERT` secret
(`avn project ca-get --project PROJECT`).

### After deployment

The app is reachable at the Runtime service's public URL on port 8080. Health
check: `GET /actuator/health`.

## 3. Locking down the UI

The UI ships **without authentication**, so anyone with the URL can reach it.
`KAFKA_CLUSTERS_0_READONLY=true` is on by default to limit the blast radius — no
one can create, produce or delete from the UI.

To close it off, two options on the Kafbat side:

```yaml
# Simple form login
AUTH_TYPE: LOGIN_FORM
SPRING_SECURITY_USER_NAME: admin
SPRING_SECURITY_USER_PASSWORD: <Runtime secret>
```

or OAuth2/OIDC (`AUTH_TYPE: OAUTH2`) against your company provider, then Kafbat
RBAC for roles. Say the word and I'll add the config.

## Good practice

- Create a **dedicated Kafka user** for the UI rather than using `avnadmin`, with
  read ACLs on the topics you want to expose.
- Keep `DYNAMIC_CONFIG_ENABLED=false`, otherwise any visitor can add a cluster
  from the UI.
- `certs/`, `.env` and any PEM/JKS files are excluded by `.gitignore` — the
  repository should never hold credentials.

## References

- [Aiven Runtime — Compose files](https://aiven.io/docs/products/runtime/manifest-files/compose-files)
- [Aiven Runtime — Connect services (including Karapace)](https://aiven.io/docs/products/runtime/connect-services-to-apps)
- [Aiven Runtime — Secrets and variables](https://aiven.io/docs/products/runtime/secrets-and-variables)
- [Kafbat UI — SASL_SCRAM](https://ui.docs.kafbat.io/configuration/authentication/for-kafka/sasl_scram)
- [Kafbat UI — Configuration file](https://ui.docs.kafbat.io/configuration/configuration-file)
