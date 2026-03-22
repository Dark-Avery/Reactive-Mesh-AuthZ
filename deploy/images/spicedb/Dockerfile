FROM debian:bookworm-slim

ARG SPICEDB_VERSION=1.47.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tar \
    && rm -rf /var/lib/apt/lists/*

COPY spicedb_${SPICEDB_VERSION}_linux_amd64.tar.gz /tmp/spicedb.tar.gz

RUN tar -xzf /tmp/spicedb.tar.gz -C /usr/local/bin spicedb \
    && chmod +x /usr/local/bin/spicedb \
    && rm -f /tmp/spicedb.tar.gz

ENTRYPOINT ["/usr/local/bin/spicedb"]
