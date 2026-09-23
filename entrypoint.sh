#!/bin/sh
# Kafbat UI entrypoint for Aiven.
#
# Job: turn the environment variables supplied by Aiven (Runtime integration or
# manual secrets) into a working Kafbat UI configuration.
#
# Input variables
# ---------------
#   AIVEN_CA_CERT            Aiven project CA in PEM format (or KAFKA_CA_CERT,
#                            injected automatically by the Runtime integration).
#   AIVEN_CA_CERT_FILE       Path to a mounted CA file (handy locally).
#   KAFKA_SASL_USERNAME      Kafka user (e.g. avnadmin)
#   KAFKA_SASL_PASSWORD      Kafka password
#   KAFKA_SASL_MECHANISM     Defaults to SCRAM-SHA-512
#   KAFKA_BOOTSTRAP_SERVERS  host:port of Aiven's SASL_SSL listener
#   KAFKA_CLUSTER_NAME       Name shown in the UI
#   SCHEMA_REGISTRY_URL      Karapace URI (https://...)
#   SCHEMA_REGISTRY_USER     Karapace user
#   SCHEMA_REGISTRY_PASSWORD Karapace password
#   KAFKA_ACCESS_KEY / KAFKA_ACCESS_CERT   (optional) switches to mTLS
#
# Any KAFKA_CLUSTERS_0_* variable that is already set is left alone: this script
# only fills in the gaps.
set -eu

CERT_DIR="${AIVEN_CERT_DIR:-/etc/kafkaui}"
TRUSTSTORE="$CERT_DIR/aiven-truststore.jks"
TRUSTSTORE_PASSWORD="${AIVEN_TRUSTSTORE_PASSWORD:-changeit}"
CA_PEM="$CERT_DIR/aiven-ca.pem"

log() { echo "[aiven-entrypoint] $*"; }

# Write a PEM value coming from an environment variable to a file.
# Handles the case where newlines are escaped as a literal \n.
write_pem() {
    _value="$1"
    _target="$2"
    case "$_value" in
        *'\n'*) printf '%b\n' "$_value" > "$_target" ;;
        *)      printf '%s\n' "$_value" > "$_target" ;;
    esac
    chmod 600 "$_target"
}

# -----------------------------------------------------------------------------
# 1. Truststore: Aiven project CA added to the JVM's public CAs
# -----------------------------------------------------------------------------
CA_CERT="${AIVEN_CA_CERT:-${KAFKA_CA_CERT:-}}"

# Locally, a multi-line PEM travels badly through a .env file, so a mounted file
# is accepted too.
if [ -z "$CA_CERT" ] && [ -n "${AIVEN_CA_CERT_FILE:-}" ] && [ -f "$AIVEN_CA_CERT_FILE" ]; then
    CA_CERT="$(cat "$AIVEN_CA_CERT_FILE")"
fi

if [ -n "$CA_CERT" ]; then
    mkdir -p "$CERT_DIR"
    write_pem "$CA_CERT" "$CA_PEM"

    # Start from the JVM's cacerts so we don't lose trust in the public CAs
    # (useful later on for OAuth, webhooks and the like).
    SYSTEM_CACERTS=""
    for candidate in \
        "${JAVA_HOME:-}/lib/security/cacerts" \
        "${JAVA_HOME:-}/jre/lib/security/cacerts" \
        /usr/lib/jvm/default-jvm/lib/security/cacerts \
        /etc/ssl/certs/java/cacerts
    do
        [ -f "$candidate" ] && { SYSTEM_CACERTS="$candidate"; break; }
    done
    if [ -z "$SYSTEM_CACERTS" ]; then
        SYSTEM_CACERTS="$(find / -name cacerts -type f 2>/dev/null | head -n 1 || true)"
    fi

    if [ -n "$SYSTEM_CACERTS" ] && [ -f "$SYSTEM_CACERTS" ]; then
        cp "$SYSTEM_CACERTS" "$TRUSTSTORE"
        SOURCE_PASSWORD=changeit
    else
        log "System cacerts not found, creating an empty truststore"
        rm -f "$TRUSTSTORE"
        SOURCE_PASSWORD="$TRUSTSTORE_PASSWORD"
    fi

    if [ "$SOURCE_PASSWORD" != "$TRUSTSTORE_PASSWORD" ]; then
        keytool -storepasswd -keystore "$TRUSTSTORE" \
            -storepass "$SOURCE_PASSWORD" -new "$TRUSTSTORE_PASSWORD" >/dev/null
    fi

    keytool -importcert -noprompt -alias aiven-project-ca \
        -file "$CA_PEM" -keystore "$TRUSTSTORE" \
        -storepass "$TRUSTSTORE_PASSWORD" >/dev/null
    log "Aiven CA imported into $TRUSTSTORE"

    # Truststore used by the Kafka client...
    : "${KAFKA_CLUSTERS_0_SSL_TRUSTSTORELOCATION:=$TRUSTSTORE}"
    : "${KAFKA_CLUSTERS_0_SSL_TRUSTSTOREPASSWORD:=$TRUSTSTORE_PASSWORD}"
    export KAFKA_CLUSTERS_0_SSL_TRUSTSTORELOCATION KAFKA_CLUSTERS_0_SSL_TRUSTSTOREPASSWORD

    # ...and by the JVM's HTTP clients (Karapace / Kafka Connect over HTTPS,
    # whose certificates are signed by the same private CA).
    JAVA_OPTS="${JAVA_OPTS:-} -Djavax.net.ssl.trustStore=$TRUSTSTORE -Djavax.net.ssl.trustStorePassword=$TRUSTSTORE_PASSWORD"
    export JAVA_OPTS
else
    log "WARNING: no CA supplied (AIVEN_CA_CERT / KAFKA_CA_CERT are empty)."
    log "The TLS connection to Aiven will most likely fail."
fi

# -----------------------------------------------------------------------------
# 2. Cluster: bootstrap servers and display name
# -----------------------------------------------------------------------------
: "${KAFKA_CLUSTERS_0_NAME:=${KAFKA_CLUSTER_NAME:-aiven-kafka}}"
export KAFKA_CLUSTERS_0_NAME

if [ -z "${KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS:-}" ] && [ -n "${KAFKA_BOOTSTRAP_SERVERS:-}" ]; then
    KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS="$KAFKA_BOOTSTRAP_SERVERS"
    export KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS
fi

if [ -z "${KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS:-}" ]; then
    log "ERROR: KAFKA_BOOTSTRAP_SERVERS is not set."
    exit 1
fi

# -----------------------------------------------------------------------------
# 3. Authentication: SASL/SCRAM by default, mTLS if client certs are present
# -----------------------------------------------------------------------------
if [ -n "${KAFKA_SASL_USERNAME:-}" ] && [ -n "${KAFKA_SASL_PASSWORD:-}" ]; then
    : "${KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL:=SASL_SSL}"
    : "${KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM:=${KAFKA_SASL_MECHANISM:-SCRAM-SHA-512}}"

    case "$KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM" in
        SCRAM-*) LOGIN_MODULE=org.apache.kafka.common.security.scram.ScramLoginModule ;;
        PLAIN)   LOGIN_MODULE=org.apache.kafka.common.security.plain.PlainLoginModule ;;
        *)       log "Unsupported SASL mechanism: $KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM"; exit 1 ;;
    esac

    : "${KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG:=$LOGIN_MODULE required username=\"$KAFKA_SASL_USERNAME\" password=\"$KAFKA_SASL_PASSWORD\";}"

    export KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL \
           KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM \
           KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG
    log "Kafka auth: $KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL / $KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM (user $KAFKA_SASL_USERNAME)"

elif [ -n "${KAFKA_ACCESS_KEY:-}" ] && [ -n "${KAFKA_ACCESS_CERT:-}" ]; then
    # mTLS variant: client key and certificate provided by the Runtime integration.
    mkdir -p "$CERT_DIR"
    write_pem "$KAFKA_ACCESS_KEY" "$CERT_DIR/service.key"
    write_pem "$KAFKA_ACCESS_CERT" "$CERT_DIR/service.cert"
    cat "$CERT_DIR/service.key" "$CERT_DIR/service.cert" > "$CERT_DIR/client.pem"
    chmod 600 "$CERT_DIR/client.pem"

    : "${KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL:=SSL}"
    : "${KAFKA_CLUSTERS_0_PROPERTIES_SSL_KEYSTORE_TYPE:=PEM}"
    : "${KAFKA_CLUSTERS_0_PROPERTIES_SSL_KEYSTORE_LOCATION:=$CERT_DIR/client.pem}"
    export KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL \
           KAFKA_CLUSTERS_0_PROPERTIES_SSL_KEYSTORE_TYPE \
           KAFKA_CLUSTERS_0_PROPERTIES_SSL_KEYSTORE_LOCATION
    log "Kafka auth: mTLS (client certificate)"
else
    log "WARNING: neither SASL credentials nor a client certificate were supplied."
fi

# -----------------------------------------------------------------------------
# 4. Schema Registry (Karapace)
# -----------------------------------------------------------------------------
if [ -n "${SCHEMA_REGISTRY_URL:-}" ]; then
    : "${KAFKA_CLUSTERS_0_SCHEMAREGISTRY:=$SCHEMA_REGISTRY_URL}"
    export KAFKA_CLUSTERS_0_SCHEMAREGISTRY
    if [ -n "${SCHEMA_REGISTRY_USER:-}" ]; then
        : "${KAFKA_CLUSTERS_0_SCHEMAREGISTRYAUTH_USERNAME:=$SCHEMA_REGISTRY_USER}"
        : "${KAFKA_CLUSTERS_0_SCHEMAREGISTRYAUTH_PASSWORD:=${SCHEMA_REGISTRY_PASSWORD:-}}"
        export KAFKA_CLUSTERS_0_SCHEMAREGISTRYAUTH_USERNAME \
               KAFKA_CLUSTERS_0_SCHEMAREGISTRYAUTH_PASSWORD
    fi
    log "Schema Registry: $KAFKA_CLUSTERS_0_SCHEMAREGISTRY"
fi

# -----------------------------------------------------------------------------
# 5. Kafka Connect (optional)
# -----------------------------------------------------------------------------
if [ -n "${KAFKA_CONNECT_URL:-}" ]; then
    : "${KAFKA_CLUSTERS_0_KAFKACONNECT_0_NAME:=aiven-connect}"
    : "${KAFKA_CLUSTERS_0_KAFKACONNECT_0_ADDRESS:=$KAFKA_CONNECT_URL}"
    export KAFKA_CLUSTERS_0_KAFKACONNECT_0_NAME KAFKA_CLUSTERS_0_KAFKACONNECT_0_ADDRESS
    if [ -n "${KAFKA_CONNECT_USER:-}" ]; then
        : "${KAFKA_CLUSTERS_0_KAFKACONNECT_0_USERNAME:=$KAFKA_CONNECT_USER}"
        : "${KAFKA_CLUSTERS_0_KAFKACONNECT_0_PASSWORD:=${KAFKA_CONNECT_PASSWORD:-}}"
        export KAFKA_CLUSTERS_0_KAFKACONNECT_0_USERNAME KAFKA_CLUSTERS_0_KAFKACONNECT_0_PASSWORD
    fi
fi

# -----------------------------------------------------------------------------
# 6. Miscellaneous
# -----------------------------------------------------------------------------
# Aiven Runtime routes traffic to the exposed port; 8080 is the image's own.
: "${SERVER_PORT:=8080}"
export SERVER_PORT

# Spring Boot Actuator health probe: /actuator/health
: "${MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE:=info,health,prometheus}"
export MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE

log "Starting Kafbat UI on port $SERVER_PORT"

# shellcheck disable=SC2086 # JAVA_OPTS must be word-split
exec java --add-opens java.rmi/javax.rmi.ssl=ALL-UNNAMED ${JAVA_OPTS:-} -jar /api.jar
