#!/bin/sh
# Kafbat UI entrypoint for Aiven — multi-cluster capable.
#
# Job: turn flat environment variables (Runtime variables and secrets) into a
# working Kafbat UI configuration, including the truststore work that Aiven's
# private CAs require.
#
# Per-cluster input variables, where N is 0, 1, 2, ...
# ---------------------------------------------------
#   KAFKA_N_NAME                  Display name in the UI (default: cluster-N)
#   KAFKA_N_BOOTSTRAP_SERVERS     host:port — REQUIRED, this is what declares
#                                 that cluster N exists
#   KAFKA_N_SECURITY_PROTOCOL     Override; inferred when omitted (see below)
#   KAFKA_N_SASL_MECHANISM        SCRAM-SHA-512 (default), SCRAM-SHA-256, PLAIN
#   KAFKA_N_SASL_USERNAME         SASL user
#   KAFKA_N_SASL_PASSWORD         SASL password
#   KAFKA_N_CA_CERT               CA in PEM format, for a private CA
#   KAFKA_N_CA_CERT_FILE          ...or a path to a mounted PEM file
#   KAFKA_N_ACCESS_KEY            mTLS client key (PEM)
#   KAFKA_N_ACCESS_CERT           mTLS client certificate (PEM)
#   KAFKA_N_SCHEMA_REGISTRY_URL   Karapace / Schema Registry URI
#   KAFKA_N_SCHEMA_REGISTRY_USER
#   KAFKA_N_SCHEMA_REGISTRY_PASSWORD
#   KAFKA_N_CONNECT_URL           Kafka Connect REST endpoint
#   KAFKA_N_CONNECT_USER
#   KAFKA_N_CONNECT_PASSWORD
#   KAFKA_N_READONLY              true|false (default: true)
#
# Protocol inference, when KAFKA_N_SECURITY_PROTOCOL is not set:
#   SASL user + password  -> SASL_SSL   (Aiven, Confluent Cloud, MSK SASL/SCRAM)
#   mTLS key + cert       -> SSL        (Aiven mTLS)
#   neither               -> PLAINTEXT  (a local or in-VPC broker)
#
# Single-cluster shorthand (backwards compatible, maps to cluster 0):
#   KAFKA_CLUSTER_NAME, KAFKA_BOOTSTRAP_SERVERS, KAFKA_SASL_*, AIVEN_CA_CERT,
#   AIVEN_CA_CERT_FILE, KAFKA_CA_CERT (Runtime integration), KAFKA_ACCESS_KEY,
#   KAFKA_ACCESS_CERT, SCHEMA_REGISTRY_*, KAFKA_CONNECT_*
#
# Any KAFKA_CLUSTERS_<i>_* variable set directly in the environment always wins:
# this script only fills in the gaps. See README for the escape hatch.
set -eu

CERT_DIR="${AIVEN_CERT_DIR:-/etc/kafkaui}"
TRUSTSTORE="$CERT_DIR/aiven-truststore.jks"
TRUSTSTORE_PASSWORD="${AIVEN_TRUSTSTORE_PASSWORD:-changeit}"
MAX_CLUSTERS="${KAFKA_MAX_CLUSTERS:-16}"

log() { echo "[aiven-entrypoint] $*"; }

# Read a variable by name: getvar KAFKA_0_NAME
getvar() { eval "printf '%s' \"\${$1:-}\""; }

# Set a variable by name and export it, unless it already holds a value.
# The value is passed as a positional parameter so it is never re-parsed.
setvar() {
    eval "_cur=\${$1:-}"
    [ -n "$_cur" ] && return 0
    eval "$1=\$2"
    export "$1"
}

# Copy a legacy unindexed variable onto its cluster-0 equivalent.
alias_legacy() {
    _legacy="$(getvar "$1")"
    [ -n "$_legacy" ] && setvar "$2" "$_legacy"
    return 0
}

# Escape a value for inclusion in a quoted JAAS field. Aiven passwords are
# alphanumeric, but a non-Aiven cluster's API secret may well contain " or \,
# which would otherwise terminate the JAAS string early.
jaas_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Write a PEM value to a file, handling newlines escaped as a literal \n.
write_pem() {
    case "$1" in
        *'\n'*) printf '%b\n' "$1" > "$2" ;;
        *)      printf '%s\n' "$1" > "$2" ;;
    esac
    chmod 600 "$2"
}

mkdir -p "$CERT_DIR"

# -----------------------------------------------------------------------------
# 0. Single-cluster shorthand -> cluster 0
# -----------------------------------------------------------------------------
alias_legacy KAFKA_CLUSTER_NAME          KAFKA_0_NAME
alias_legacy KAFKA_BOOTSTRAP_SERVERS     KAFKA_0_BOOTSTRAP_SERVERS
alias_legacy KAFKA_SECURITY_PROTOCOL_OVERRIDE KAFKA_0_SECURITY_PROTOCOL
alias_legacy KAFKA_SASL_MECHANISM        KAFKA_0_SASL_MECHANISM
alias_legacy KAFKA_SASL_USERNAME         KAFKA_0_SASL_USERNAME
alias_legacy KAFKA_SASL_PASSWORD         KAFKA_0_SASL_PASSWORD
alias_legacy AIVEN_CA_CERT               KAFKA_0_CA_CERT
alias_legacy KAFKA_CA_CERT               KAFKA_0_CA_CERT
alias_legacy AIVEN_CA_CERT_FILE          KAFKA_0_CA_CERT_FILE
alias_legacy KAFKA_ACCESS_KEY            KAFKA_0_ACCESS_KEY
alias_legacy KAFKA_ACCESS_CERT           KAFKA_0_ACCESS_CERT
alias_legacy SCHEMA_REGISTRY_URL         KAFKA_0_SCHEMA_REGISTRY_URL
alias_legacy SCHEMA_REGISTRY_USER        KAFKA_0_SCHEMA_REGISTRY_USER
alias_legacy SCHEMA_REGISTRY_PASSWORD    KAFKA_0_SCHEMA_REGISTRY_PASSWORD
alias_legacy KAFKA_CONNECT_URL           KAFKA_0_CONNECT_URL
alias_legacy KAFKA_CONNECT_USER          KAFKA_0_CONNECT_USER
alias_legacy KAFKA_CONNECT_PASSWORD      KAFKA_0_CONNECT_PASSWORD

# Note: KAFKA_SECURITY_PROTOCOL is deliberately NOT aliased. The Runtime
# integration sets it to SSL for its mTLS credentials, which would silently
# override a SASL_SSL setup. Use KAFKA_SECURITY_PROTOCOL_OVERRIDE, or
# KAFKA_0_SECURITY_PROTOCOL, to force a protocol.

# -----------------------------------------------------------------------------
# 1. Shared truststore: every private CA in one store
# -----------------------------------------------------------------------------
# One store for all clusters, also handed to the JVM's HTTP clients so HTTPS
# calls to Karapace and Kafka Connect trust the same CAs. Built from the JVM's
# cacerts so public CAs keep working.
truststore_init() {
    [ -f "$TRUSTSTORE" ] && return 0

    _source=""
    for _candidate in \
        "${JAVA_HOME:-}/lib/security/cacerts" \
        "${JAVA_HOME:-}/jre/lib/security/cacerts" \
        /usr/lib/jvm/default-jvm/lib/security/cacerts \
        /etc/ssl/certs/java/cacerts
    do
        [ -f "$_candidate" ] && { _source="$_candidate"; break; }
    done
    [ -z "$_source" ] && _source="$(find / -name cacerts -type f 2>/dev/null | head -n 1 || true)"

    if [ -n "$_source" ] && [ -f "$_source" ]; then
        cp "$_source" "$TRUSTSTORE"
        if [ "$TRUSTSTORE_PASSWORD" != "changeit" ]; then
            keytool -storepasswd -keystore "$TRUSTSTORE" \
                -storepass changeit -new "$TRUSTSTORE_PASSWORD" >/dev/null
        fi
        log "Truststore seeded from the JVM cacerts"
    else
        log "System cacerts not found: starting from an empty truststore"
    fi
}

# truststore_add_ca <alias> <pem-content>
truststore_add_ca() {
    truststore_init
    _pem="$CERT_DIR/ca-$1.pem"
    write_pem "$2" "$_pem"
    keytool -importcert -noprompt -alias "$1" \
        -file "$_pem" -keystore "$TRUSTSTORE" \
        -storepass "$TRUSTSTORE_PASSWORD" >/dev/null
    log "CA imported: $1"
}

# -----------------------------------------------------------------------------
# 2. Configure one cluster: configure_cluster <source-index> <kafbat-index>
# -----------------------------------------------------------------------------
configure_cluster() {
    src="$1"
    dst="$2"
    prefix="KAFKA_${src}_"
    out="KAFKA_CLUSTERS_${dst}_"

    bootstrap="$(getvar "${prefix}BOOTSTRAP_SERVERS")"
    name="$(getvar "${prefix}NAME")"
    [ -z "$name" ] && name="cluster-$src"

    setvar "${out}NAME" "$name"
    setvar "${out}BOOTSTRAPSERVERS" "$bootstrap"

    # --- Private CA -----------------------------------------------------------
    ca="$(getvar "${prefix}CA_CERT")"
    ca_file="$(getvar "${prefix}CA_CERT_FILE")"
    if [ -z "$ca" ] && [ -n "$ca_file" ] && [ -f "$ca_file" ]; then
        ca="$(cat "$ca_file")"
    fi
    if [ -n "$ca" ]; then
        truststore_add_ca "ca-$src" "$ca"
        setvar "${out}SSL_TRUSTSTORELOCATION" "$TRUSTSTORE"
        setvar "${out}SSL_TRUSTSTOREPASSWORD" "$TRUSTSTORE_PASSWORD"
        USE_JVM_TRUSTSTORE=yes
    fi

    # --- Authentication -------------------------------------------------------
    sasl_user="$(getvar "${prefix}SASL_USERNAME")"
    sasl_pass="$(getvar "${prefix}SASL_PASSWORD")"
    access_key="$(getvar "${prefix}ACCESS_KEY")"
    access_cert="$(getvar "${prefix}ACCESS_CERT")"
    protocol="$(getvar "${prefix}SECURITY_PROTOCOL")"

    if [ -n "$sasl_user" ] && [ -n "$sasl_pass" ]; then
        mechanism="$(getvar "${prefix}SASL_MECHANISM")"
        [ -z "$mechanism" ] && mechanism=SCRAM-SHA-512
        case "$mechanism" in
            SCRAM-*) module=org.apache.kafka.common.security.scram.ScramLoginModule ;;
            PLAIN)   module=org.apache.kafka.common.security.plain.PlainLoginModule ;;
            *)       log "ERROR: unsupported SASL mechanism for cluster $src: $mechanism"; exit 1 ;;
        esac
        [ -z "$protocol" ] && protocol=SASL_SSL
        setvar "${out}PROPERTIES_SECURITY_PROTOCOL" "$protocol"
        setvar "${out}PROPERTIES_SASL_MECHANISM" "$mechanism"
        setvar "${out}PROPERTIES_SASL_JAAS_CONFIG" \
            "$module required username=\"$(jaas_escape "$sasl_user")\" password=\"$(jaas_escape "$sasl_pass")\";"
        auth_desc="$protocol / $mechanism as $sasl_user"

    elif [ -n "$access_key" ] && [ -n "$access_cert" ]; then
        write_pem "$access_key" "$CERT_DIR/client-$src.key"
        write_pem "$access_cert" "$CERT_DIR/client-$src.cert"
        cat "$CERT_DIR/client-$src.key" "$CERT_DIR/client-$src.cert" \
            > "$CERT_DIR/client-$src.pem"
        chmod 600 "$CERT_DIR/client-$src.pem"
        [ -z "$protocol" ] && protocol=SSL
        setvar "${out}PROPERTIES_SECURITY_PROTOCOL" "$protocol"
        setvar "${out}PROPERTIES_SSL_KEYSTORE_TYPE" "PEM"
        setvar "${out}PROPERTIES_SSL_KEYSTORE_LOCATION" "$CERT_DIR/client-$src.pem"
        auth_desc="$protocol / mTLS client certificate"

    else
        [ -z "$protocol" ] && protocol=PLAINTEXT
        setvar "${out}PROPERTIES_SECURITY_PROTOCOL" "$protocol"
        auth_desc="$protocol / no credentials"
    fi

    # --- Schema Registry ------------------------------------------------------
    # The SchemaRegistry serde only registers itself when a registry URL is set.
    # Asking for it as the default value serde without one makes
    # DeserializationService throw at startup, so the two are tied together here.
    sr_url="$(getvar "${prefix}SCHEMA_REGISTRY_URL")"
    if [ -n "$sr_url" ]; then
        setvar "${out}SCHEMAREGISTRY" "$sr_url"
        sr_user="$(getvar "${prefix}SCHEMA_REGISTRY_USER")"
        if [ -n "$sr_user" ]; then
            setvar "${out}SCHEMAREGISTRYAUTH_USERNAME" "$sr_user"
            setvar "${out}SCHEMAREGISTRYAUTH_PASSWORD" \
                "$(getvar "${prefix}SCHEMA_REGISTRY_PASSWORD")"
        fi
        setvar "${out}DEFAULTVALUESERDE" "SchemaRegistry"
        sr_desc="registry $sr_url"
    else
        if [ "$(getvar "${out}DEFAULTVALUESERDE")" = "SchemaRegistry" ]; then
            log "WARNING: cluster $name asks for the SchemaRegistry serde without a registry — ignoring."
            unset "${out}DEFAULTVALUESERDE"
        fi
        sr_desc="no registry"
    fi

    # --- Kafka Connect --------------------------------------------------------
    connect_url="$(getvar "${prefix}CONNECT_URL")"
    if [ -n "$connect_url" ]; then
        setvar "${out}KAFKACONNECT_0_NAME" "connect"
        setvar "${out}KAFKACONNECT_0_ADDRESS" "$connect_url"
        connect_user="$(getvar "${prefix}CONNECT_USER")"
        if [ -n "$connect_user" ]; then
            setvar "${out}KAFKACONNECT_0_USERNAME" "$connect_user"
            setvar "${out}KAFKACONNECT_0_PASSWORD" \
                "$(getvar "${prefix}CONNECT_PASSWORD")"
        fi
        sr_desc="$sr_desc, connect"
    fi

    # --- Read-only ------------------------------------------------------------
    readonly_flag="$(getvar "${prefix}READONLY")"
    [ -z "$readonly_flag" ] && readonly_flag=true
    setvar "${out}READONLY" "$readonly_flag"

    log "Cluster $dst \"$name\": $bootstrap — $auth_desc — $sr_desc — read-only=$readonly_flag"
}

# -----------------------------------------------------------------------------
# 3. Walk the indices and configure whatever is declared
# -----------------------------------------------------------------------------
# Source indices need not be contiguous: gaps are skipped, and Kafbat gets a
# contiguous 0..n-1 list, which its config binding requires.
USE_JVM_TRUSTSTORE=no
dst_index=0
src_index=0
while [ "$src_index" -lt "$MAX_CLUSTERS" ]; do
    if [ -n "$(getvar "KAFKA_${src_index}_BOOTSTRAP_SERVERS")" ]; then
        configure_cluster "$src_index" "$dst_index"
        dst_index=$((dst_index + 1))
    fi
    src_index=$((src_index + 1))
done

if [ "$dst_index" -eq 0 ]; then
    log "ERROR: no cluster configured. Set KAFKA_BOOTSTRAP_SERVERS (single"
    log "       cluster) or KAFKA_0_BOOTSTRAP_SERVERS, KAFKA_1_..., etc."
    exit 1
fi
log "$dst_index cluster(s) configured"

# -----------------------------------------------------------------------------
# 4. JVM-wide trust, for HTTPS calls to Karapace and Kafka Connect
# -----------------------------------------------------------------------------
if [ "$USE_JVM_TRUSTSTORE" = yes ]; then
    JAVA_OPTS="${JAVA_OPTS:-} -Djavax.net.ssl.trustStore=$TRUSTSTORE -Djavax.net.ssl.trustStorePassword=$TRUSTSTORE_PASSWORD"
    export JAVA_OPTS
else
    log "No private CA supplied: relying on the JVM's default trust store."
fi

# -----------------------------------------------------------------------------
# 5. Miscellaneous
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
