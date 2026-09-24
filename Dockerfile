# Kafbat UI packaged for Aiven Runtime.
#
# Starts from the official image and adds an entrypoint that materialises the
# Aiven project CA certificates (passed in as environment variables) into a Java
# truststore, expands the KAFKA_N_* variables into Kafbat's cluster config, sets
# up UI authentication, then starts the application.
#
# The base image runs as the non-root `kafkaui` user; /etc/kafkaui is the
# writable directory intended for certificates, so that is where we work.
FROM ghcr.io/kafbat/kafka-ui:latest

# Aiven Runtime reads EXPOSE to detect the application's HTTP port.
EXPOSE 8080

COPY entrypoint.sh /entrypoint.sh

# RBAC roles, if any. Runtime has no volumes, so the file has to be baked in:
# commit config/roles.yml and it is loaded at startup (OAuth2/LDAP only).
# It holds group names, never secrets — those stay Runtime secrets.
COPY config/ /config/

# Invoked through /bin/sh so the executable bit doesn't need to survive a clone.
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
