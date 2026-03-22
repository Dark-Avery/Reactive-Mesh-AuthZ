FROM ubuntu:24.04 AS builder
WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake pkg-config protobuf-compiler protobuf-compiler-grpc \
    libprotobuf-dev libgrpc++-dev libgrpc-dev && \
    rm -rf /var/lib/apt/lists/*

COPY grpc/ /src/grpc/
RUN cmake -S /src/grpc -B /src/build && cmake --build /src/build --target grpc-client -j"$(nproc)"

FROM ubuntu:24.04
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    libprotobuf32t64 libgrpc++1.51t64 libgrpc29t64 libabsl20220623t64 libc6 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/build/grpc-client /app/grpc-client
ENTRYPOINT ["/app/grpc-client"]
