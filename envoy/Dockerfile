# syntax=docker/dockerfile:1.7
# Build custom Envoy + C++ filter inside an Envoy CI build image, then copy the binary into a clean runtime image.

ARG ENVOY_BUILD_IMAGE=envoyproxy/envoy-build-ubuntu:full-86873047235e9b8232df989a5999b9bebf9db69c
ARG ENVOY_REF=v1.37.0
ARG ENVOY_CONFIG=envoy-reactive.yaml
ARG BAZEL_JOBS=16
ARG BAZEL_CPU=16
ARG BAZEL_RAM_MB=32768

FROM ${ENVOY_BUILD_IMAGE} AS builder-base
ARG ENVOY_REF
ARG BAZEL_JOBS
ARG BAZEL_CPU
ARG BAZEL_RAM_MB

WORKDIR /workspace/envoy-custom

# Copy wrapper metadata first so small filter changes do not invalidate the
# dependency preparation layers.
COPY envoy-custom/.bazelrc /workspace/envoy-custom/.bazelrc
COPY envoy-custom/.bazelversion /workspace/envoy-custom/.bazelversion
COPY envoy-custom/BUILD /workspace/envoy-custom/BUILD
COPY envoy-custom/WORKSPACE /workspace/envoy-custom/WORKSPACE
COPY envoy/docker-patches/ /workspace/docker-patches/

# CI must be able to build from a clean checkout without local vendored Envoy
# sources or predownloaded distfiles.
RUN git clone --branch "${ENVOY_REF}" --depth 1 https://github.com/envoyproxy/envoy /workspace/envoy-custom/envoy

# Mirror bazel/ at the wrapper root for Envoy's workspace scripts.
RUN python3 /workspace/docker-patches/patch_python_dependencies.py
RUN python3 /workspace/docker-patches/patch_go_dependencies.py
RUN python3 /workspace/docker-patches/patch_requirements.py
RUN chmod +x /workspace/docker-patches/prefetch_distfiles.sh && \
    /workspace/docker-patches/prefetch_distfiles.sh
RUN ln -s envoy/.git .git && \
    ln -s envoy/bazel bazel

FROM builder-base AS builder

COPY envoy-custom/reactive_pep/ /workspace/envoy-custom/reactive_pep/

# Match the Bazel version pinned by Envoy v1.37.0.
ENV USE_BAZEL_VERSION=7.7.1
ENV BAZEL_JOBS=${BAZEL_JOBS}
ENV BAZEL_CPU=${BAZEL_CPU}
ENV BAZEL_RAM_MB=${BAZEL_RAM_MB}
RUN --mount=type=cache,target=/root/.cache/bazel \
    chmod +x /workspace/docker-patches/run_bazel_build.sh && \
    /workspace/docker-patches/run_bazel_build.sh

# Runtime image: official distroless Envoy base, but with our custom binary.
FROM envoyproxy/envoy:distroless-${ENVOY_REF}
ARG ENVOY_REF
ARG ENVOY_CONFIG

# Replace Envoy binary with our custom build.
COPY --from=builder /workspace/envoy-custom/bazel-bin/envoy /usr/local/bin/envoy

# Config
COPY envoy/${ENVOY_CONFIG} /etc/envoy/envoy.yaml

EXPOSE 8081 9901

ENTRYPOINT ["/usr/local/bin/envoy"]
CMD ["-c", "/etc/envoy/envoy.yaml", "--log-level", "info"]
