# Kafbat UI packaged for Aiven Runtime.
#
# Starts from the official image and adds an entrypoint that materialises the
# Aiven project CA certificate (passed in as an environment variable) into a Java
# truststore, builds the SASL/SCRAM config, then starts the application.
#
# The base image runs as the non-root `kafkaui` user; /etc/kafkaui is the
# writable directory intended for certificates, so that is where we work.
FROM ghcr.io/kafbat/kafka-ui:latest

# Aiven Runtime reads EXPOSE to detect the application's HTTP port.
EXPOSE 8080

COPY entrypoint.sh /entrypoint.sh

# Invoked through /bin/sh so the executable bit doesn't need to survive a clone.
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
