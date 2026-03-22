FROM ubuntu:24.04 AS builder
WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev && \
    rm -rf /var/lib/apt/lists/*

COPY common/cpp /src/common/cpp
COPY receiver/cpp/main.cpp /src/receiver/cpp/main.cpp
RUN mkdir -p /out && \
    g++ -std=c++20 -O2 -pthread -I/src -o /out/receiver /src/receiver/cpp/main.cpp -lssl -lcrypto

FROM ubuntu:24.04
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3t64 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /out/receiver /app/receiver
EXPOSE 8080
ENTRYPOINT ["/app/receiver"]
