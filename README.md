# Kafbat UI on Aiven Runtime

Deploy [Kafbat UI](https://github.com/kafbat/kafka-ui) on **Aiven Runtime**, in
front of one or several Kafka clusters — Aiven services over `SASL_SSL` /
`SCRAM-SHA-512` with the **Karapace Schema Registry**, and any non-Aiven cluster
alongside them.

- [Contents](#contents)
- [Why an entrypoint rather than plain variables](#why-an-entrypoint-rather-than-plain-variables)
- [The port trap](#the-port-trap)
- [1. Run it locally first](#1-run-it-locally-first)
- [2. Deploy to Aiven Runtime](#2-deploy-to-aiven-runtime)
- [3. Several clusters in one UI](#3-several-clusters-in-one-ui)
- [4. Locking down the UI](#4-locking-down-the-ui)
- [Variable reference](#variable-reference)
- [Troubleshooting](#troubleshooting)

## Contents

| File | Purpose |
| --- | --- |
| `Dockerfile` | Official Kafbat UI image plus an Aiven-aware entrypoint |
| `entrypoint.sh` | Builds the truststore from the private CAs, then expands flat `KAFKA_N_*` variables into Kafbat's cluster config |
| `compose.yaml` | Manifest scanned by Aiven Runtime |
| `compose.dev.yaml` | Local run against the real clusters |
| `.env.example` | Annotated examples: Aiven, self-managed, Confluent Cloud, mTLS |
| `scripts/aiven-env.sh` | Collects one Aiven service into `.env` at a given cluster index (read-only) |

## Why an entrypoint rather than plain variables

Two things get in the way of a purely declarative config:

1. **Aiven CAs are private.** Service certificates are signed by the project CA,
   which is not in the JVM truststore. Without importing it, `SASL_SSL` fails and
   so do the HTTPS calls to Karapace. The entrypoint copies the JVM `cacerts`,
   adds every CA it is given, and points both the Kafka clients and the JVM's
   HTTP clients at the result. Several projects mean several CAs in one store.
2. **The Runtime integration exposes mTLS, not SCRAM.** It provides
   `KAFKA_BOOTSTRAP_SERVERS`, `KAFKA_SECURITY_PROTOCOL=SSL`, `KAFKA_ACCESS_KEY`,
   `KAFKA_ACCESS_CERT` and `KAFKA_CA_CERT`. SCRAM needs a username and password
   supplied separately — and **the right port** (see below).

On top of that, the entrypoint takes flat `KAFKA_N_*` variables and expands them
into the `KAFKA_CLUSTERS_N_*` names Kafbat expects, filling in the login module,
the JAAS string, the truststore paths and the serde defaults. That is most of the
value when more than one cluster is involved.

## The port trap

Aiven exposes Kafka on **two different ports**: one for mTLS, one for SASL. The
Runtime integration hands you the **mTLS** one. If the bootstrap address is not
overridden, the SASL connection fails with an unhelpful timeout.

The SASL port is in Console → Kafka service → *Overview* → *Connection
information* → **SASL** tab. The SASL method has to be enabled on the service
first:

```bash
avn service update SERVICE --project PROJECT -c kafka_authentication_methods.sasl=true
```

Note that `KAFKA_SECURITY_PROTOCOL` from the integration is deliberately
**ignored** by the entrypoint, so its `SSL` value cannot silently override a
SASL setup. To force a protocol, use `KAFKA_N_SECURITY_PROTOCOL`.

## 1. Run it locally first

```bash
./scripts/aiven-env.sh my-project my-kafka-service   # or: cp .env.example .env
docker compose -f compose.dev.yaml up --build
open http://localhost:8080
```

If the UI lists your topics locally, the same config will work on Runtime. The
`[aiven-entrypoint]` lines at the top of the logs summarise what was detected
for each cluster — protocol, mechanism, registry, read-only — and are the
fastest way to spot a missing variable.

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

### Minimum variables for one cluster

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
| `KAFKA_0_READONLY` | variable | `true` while the UI is unprotected |

These unindexed names are a shorthand for cluster 0. `KAFKA_CA_CERT` is injected
by the integration, so there is nothing to do for the CA. Without an integration,
supply the project CA in an `AIVEN_CA_CERT` secret
(`avn project ca-get --project PROJECT`).

The app is then reachable at the Runtime service's public URL on port 8080.
Health check: `GET /actuator/health`.

## 3. Several clusters in one UI

A Runtime application can only be integrated with **one** Aiven service, so
extra clusters are not declared in `compose.yaml` — they are added as Runtime
variables and secrets, and the entrypoint picks them up. Nothing in the repo
needs to change to add a cluster.

### The naming scheme

Every cluster is a numbered block. `KAFKA_N_BOOTSTRAP_SERVERS` is what declares
that cluster `N` exists; everything else is optional.

```
KAFKA_0_NAME=aiven-prod                    KAFKA_1_NAME=aiven-staging
KAFKA_0_BOOTSTRAP_SERVERS=prod:12345       KAFKA_1_BOOTSTRAP_SERVERS=stg:12345
KAFKA_0_SASL_USERNAME=avnadmin             KAFKA_1_SASL_USERNAME=avnadmin
KAFKA_0_SASL_PASSWORD=<secret>             KAFKA_1_SASL_PASSWORD=<secret>
KAFKA_0_CA_CERT=<secret, PEM>              KAFKA_1_CA_CERT=<secret, PEM>
KAFKA_0_READONLY=true                      KAFKA_1_READONLY=false
```

Indices need not be contiguous: gaps are skipped and Kafbat still receives a
contiguous list, which its config binding requires. So deleting cluster 1 of
0/1/2 is safe — but note that the **display** indices shift, which matters only
if you also set raw `KAFKA_CLUSTERS_N_*` variables (see the escape hatch below).

The unindexed shorthand (`KAFKA_BOOTSTRAP_SERVERS`, `SCHEMA_REGISTRY_URL`, …)
always maps to cluster 0, so a single-cluster setup can stay as it is and grow
by adding a `KAFKA_1_*` block. Mixing both styles for cluster 0 also works; the
indexed form wins.

### Protocol inference

You rarely need to set `KAFKA_N_SECURITY_PROTOCOL` — it follows from the
credentials you supply:

| What you provide | Inferred protocol | Typical case |
| --- | --- | --- |
| SASL username + password | `SASL_SSL` | Aiven, Confluent Cloud, MSK SASL/SCRAM |
| `ACCESS_KEY` + `ACCESS_CERT` | `SSL` | Aiven mTLS |
| Neither | `PLAINTEXT` | Local or in-VPC broker |

Set it explicitly for the cases inference cannot guess, such as `SASL_PLAINTEXT`
for an internal broker with SCRAM but no TLS.

### Four clusters, mixed estate

A realistic Runtime configuration:

```bash
# 0 — Aiven production, read-only, with Karapace
KAFKA_0_NAME=aiven-prod
KAFKA_0_BOOTSTRAP_SERVERS=kafka-prod-myorg.aivencloud.com:12693   # SASL port
KAFKA_0_SASL_USERNAME=kafbat-ui
KAFKA_0_SASL_PASSWORD=…                       # secret
KAFKA_0_CA_CERT=…                             # secret, project A's CA
KAFKA_0_SCHEMA_REGISTRY_URL=https://kafka-prod-myorg.aivencloud.com:12694
KAFKA_0_SCHEMA_REGISTRY_USER=kafbat-ui
KAFKA_0_SCHEMA_REGISTRY_PASSWORD=…            # secret
KAFKA_0_READONLY=true

# 1 — Aiven staging, in a different project, so a different CA; writes allowed
KAFKA_1_NAME=aiven-staging
KAFKA_1_BOOTSTRAP_SERVERS=kafka-stg-myorg.aivencloud.com:12693
KAFKA_1_SASL_USERNAME=avnadmin
KAFKA_1_SASL_PASSWORD=…                       # secret
KAFKA_1_CA_CERT=…                             # secret, project B's CA
KAFKA_1_READONLY=false

# 2 — self-managed broker reachable over the VPC peering, no TLS
KAFKA_2_NAME=legacy-onprem
KAFKA_2_BOOTSTRAP_SERVERS=broker-1.internal:9092

# 3 — Confluent Cloud: publicly trusted certificate, SASL/PLAIN
KAFKA_3_NAME=partner-confluent
KAFKA_3_BOOTSTRAP_SERVERS=pkc-abcde.eu-west-1.aws.confluent.cloud:9092
KAFKA_3_SASL_MECHANISM=PLAIN
KAFKA_3_SASL_USERNAME=…                       # API key
KAFKA_3_SASL_PASSWORD=…                       # secret, API secret
```

Points worth noting in that example:

- **One CA per Aiven project.** Two projects, two `KAFKA_N_CA_CERT` secrets. They
  land in the same truststore under distinct aliases, so they do not collide.
- **Confluent Cloud needs no CA.** Its chain is publicly trusted, and the
  entrypoint seeds the truststore from the JVM's `cacerts`, so public CAs keep
  working even once private ones are added.
- **`READONLY` is per cluster.** Locking production while leaving staging
  writable is the common arrangement.
- **Karapace is per cluster too.** A registry on cluster 0 only affects cluster
  0's default value serde; the others fall back to String/auto-detect.

### Doing the same locally

`scripts/aiven-env.sh` takes a cluster index. Index 0 rewrites `.env`; any other
index appends a block, and each service's CA is written to its own file:

```bash
./scripts/aiven-env.sh prod-project    kafka-prod    0   # rewrites .env
./scripts/aiven-env.sh staging-project kafka-staging 1   # appends
```

`compose.dev.yaml` mounts the whole `certs/` directory, so `certs/ca-0.pem` and
`certs/ca-1.pem` are both visible to the container. Non-Aiven clusters are added
to `.env` by hand — `.env.example` has a ready-made block for each shape.

### Escape hatch: raw Kafbat variables

The entrypoint only ever fills gaps. Any `KAFKA_CLUSTERS_<i>_*` variable already
present in the environment is left untouched, so anything the helper scheme does
not cover can be set directly in Kafbat's own naming:

```bash
KAFKA_CLUSTERS_0_MASKING_0_TYPE=MASK
KAFKA_CLUSTERS_0_MASKING_0_FIELDS_0=email
KAFKA_CLUSTERS_0_POLLINGTHROTTLERATE=5
KAFKA_CLUSTERS_1_KAFKACONNECT_1_NAME=second-connect-cluster
```

`<i>` here is the **final** index Kafbat sees, which is the count of declared
clusters before it — identical to your own numbering as long as you number from
0 without gaps. Beyond a handful of clusters, or if you need the full
configuration surface, mounting a YAML file
(`SPRING_CONFIG_ADDITIONAL-LOCATION`) is more readable than a wall of
variables; see the [Kafbat configuration file
reference](https://ui.docs.kafbat.io/configuration/configuration-file).

## 4. Locking down the UI

The UI ships **without authentication**, so anyone with the URL can reach every
cluster it is wired to. This matters more with each cluster you add, which is why
`READONLY` defaults to `true`: no one can create, produce or delete from the UI.

To close it off, two options on the Kafbat side:

```yaml
# Simple form login
AUTH_TYPE: LOGIN_FORM
SPRING_SECURITY_USER_NAME: admin
SPRING_SECURITY_USER_PASSWORD: <Runtime secret>
```

or OAuth2/OIDC (`AUTH_TYPE: OAUTH2`) against your company provider. With several
clusters, Kafbat **RBAC** is what you actually want — roles are scoped per
cluster, so a team can be given read access to staging and nothing on
production. Say the word and I'll add the config.

## Variable reference

`N` is the cluster index, starting at 0.

| Variable | Required | Notes |
| --- | --- | --- |
| `KAFKA_N_BOOTSTRAP_SERVERS` | yes | Declares the cluster. Use the SASL port on Aiven. |
| `KAFKA_N_NAME` | no | Display name; defaults to `cluster-N`. |
| `KAFKA_N_SECURITY_PROTOCOL` | no | Override; inferred from the credentials otherwise. |
| `KAFKA_N_SASL_MECHANISM` | no | `SCRAM-SHA-512` (default), `SCRAM-SHA-256`, `PLAIN`. |
| `KAFKA_N_SASL_USERNAME` / `_SASL_PASSWORD` | no | Enables SASL. Password belongs in a secret. |
| `KAFKA_N_CA_CERT` | no | Private CA, PEM. Required for Aiven. |
| `KAFKA_N_CA_CERT_FILE` | no | Path to a mounted PEM, for local runs. |
| `KAFKA_N_ACCESS_KEY` / `_ACCESS_CERT` | no | mTLS client credentials, PEM. |
| `KAFKA_N_SCHEMA_REGISTRY_URL` | no | Also switches the default value serde to `SchemaRegistry`. |
| `KAFKA_N_SCHEMA_REGISTRY_USER` / `_PASSWORD` | no | Basic auth on the registry. |
| `KAFKA_N_CONNECT_URL` | no | Kafka Connect REST endpoint. |
| `KAFKA_N_CONNECT_USER` / `_PASSWORD` | no | Basic auth on Connect. |
| `KAFKA_N_READONLY` | no | `true` by default. |

Global knobs: `KAFKA_MAX_CLUSTERS` (how many indices are scanned, default 16),
`AIVEN_CERT_DIR`, `AIVEN_TRUSTSTORE_PASSWORD`, `SERVER_PORT`,
`DYNAMIC_CONFIG_ENABLED`.

## Troubleshooting

### `DeserializationService ... Constructor threw exception`

```
Error creating bean with name 'messagesService' ...
Unsatisfied dependency ... 'deserializationService' ...
Failed to instantiate [io.kafbat.ui.service.DeserializationService]
```

`DEFAULTVALUESERDE=SchemaRegistry` with no Schema Registry configured. Kafbat
resolves the default serde against the serdes it managed to register, and the
SchemaRegistry serde only registers itself when `schemaRegistry` is set for that
cluster — so the lookup returns null and
`Preconditions.checkNotNull(..., "Default value serde not found")` aborts the
startup.

The entrypoint ties the two together per cluster: it sets the default serde only
when `KAFKA_N_SCHEMA_REGISTRY_URL` is present, and strips an inherited
`SchemaRegistry` default otherwise (with a warning in the logs). So either
supply the registry variables, or leave them out and let Kafbat fall back to
String/auto-detect.

### One cluster is missing from the UI

Its `KAFKA_N_BOOTSTRAP_SERVERS` is empty — that variable is the declaration. The
`N cluster(s) configured` log line tells you how many were found. Also check
`N` is below `KAFKA_MAX_CLUSTERS` (16 by default).

### A cluster appears but lists no topics

Check the port first: the Runtime integration hands you the mTLS port, while
`SASL_SSL` needs the SASL one — see [the port trap](#the-port-trap). Then check
the CA: a cluster with a private CA and no `KAFKA_N_CA_CERT` fails the TLS
handshake. The per-cluster log line shows which protocol was actually applied.

### `SSLHandshakeException: PKIX path building failed`

A private CA is missing from the truststore. Each cluster with a private CA needs
its own `KAFKA_N_CA_CERT` — a CA given for cluster 0 does not cover cluster 1 if
they belong to different Aiven projects. The `CA imported: ca-N` lines list what
made it in.

### Karapace works from curl but not from the UI

The registry is HTTPS with the same private CA, and the JVM's HTTP client needs
it too. The entrypoint handles this by pointing `javax.net.ssl.trustStore` at the
shared store — but only when at least one CA was supplied. If the logs say
"relying on the JVM's default trust store", the CA never arrived.

## References

- [Aiven Runtime — Compose files](https://aiven.io/docs/products/runtime/manifest-files/compose-files)
- [Aiven Runtime — Connect services (including Karapace)](https://aiven.io/docs/products/runtime/connect-services-to-apps)
- [Aiven Runtime — Secrets and variables](https://aiven.io/docs/products/runtime/secrets-and-variables)
- [Kafbat UI — SASL_SCRAM](https://ui.docs.kafbat.io/configuration/authentication/for-kafka/sasl_scram)
- [Kafbat UI — Configuration file](https://ui.docs.kafbat.io/configuration/configuration-file)
- [Kafbat UI — RBAC](https://ui.docs.kafbat.io/configuration/authorization/rbac)
