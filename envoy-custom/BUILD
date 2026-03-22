load(
    "@envoy//bazel:envoy_build_system.bzl",
    "envoy_cc_binary",
    "envoy_cc_library",
    "envoy_package",
)

envoy_package()

envoy_cc_library(
    name = "reactive_pep_lib",
    srcs = [
        "reactive_pep/reactive_pep_filter.cc",
        "reactive_pep/reactive_pep_filter_config.cc",
        "reactive_pep/reactive_pep_filter_factory.cc",
        "reactive_pep/redis_pubsub.cc",
        "reactive_pep/shared_state.cc",
    ],
    hdrs = [
        "reactive_pep/compat.h",
        "reactive_pep/reactive_pep_filter.h",
        "reactive_pep/reactive_pep_filter_config.h",
        "reactive_pep/redis_pubsub.h",
        "reactive_pep/shared_state.h",
    ],
    repository = "@envoy",
    deps = [
        "@envoy//source/exe:envoy_main_entry_lib",
    ],
)

envoy_cc_binary(
    name = "envoy",
    repository = "@envoy",
    deps = [
        ":reactive_pep_lib",
        "@envoy//source/exe:envoy_main_entry_lib",
    ],
)
