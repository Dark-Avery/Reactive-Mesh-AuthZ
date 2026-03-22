FROM ubuntu:24.04 AS builder
WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential && \
    rm -rf /var/lib/apt/lists/*

COPY common/cpp /src/common/cpp
COPY baseline/opa/authz_service.cpp /src/baseline/opa/authz_service.cpp
RUN mkdir -p /out && \
    g++ -std=c++20 -O2 -pthread -I/src -o /out/baseline-authz /src/baseline/opa/authz_service.cpp

FROM ubuntu:24.04
WORKDIR /app
COPY --from=builder /out/baseline-authz /app/baseline-authz
EXPOSE 9191
ENTRYPOINT ["/app/baseline-authz"]
