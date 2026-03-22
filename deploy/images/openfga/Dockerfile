FROM ubuntu:24.04 AS builder

ARG OPENFGA_VERSION=v1.12.1

WORKDIR /tmp

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    tar && \
    rm -rf /var/lib/apt/lists/*

RUN OPENFGA_VERSION_NOPREFIX="${OPENFGA_VERSION#v}" && \
    curl -fsSL -o /tmp/openfga.tar.gz \
      "https://github.com/openfga/openfga/releases/download/${OPENFGA_VERSION}/openfga_${OPENFGA_VERSION_NOPREFIX}_linux_amd64.tar.gz" && \
    mkdir -p /out && \
    tar -xzf /tmp/openfga.tar.gz -C /out

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/openfga /usr/local/bin/openfga

EXPOSE 8080 8081 3000

ENTRYPOINT ["/usr/local/bin/openfga"]
