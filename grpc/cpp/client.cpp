#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>

#include <grpcpp/grpcpp.h>

#include "stream.grpc.pb.h"

namespace {

std::string getenvOr(const char* key, const char* fallback) {
  const char* value = std::getenv(key);
  return value == nullptr || *value == '\0' ? fallback : value;
}

void usage() {
  std::cerr << "usage: grpc-client [--addr host:port] [--sub value] [--sid value] [--jti value] [--interval ms] [--bearer-token token]\n";
}

} // namespace

int main(int argc, char** argv) {
  std::string addr = getenvOr("GRPC_ADDR", "localhost:8081");
  std::string sub = "alice";
  std::string sid;
  std::string jti;
  std::string bearer_token;
  bool explicit_sub = false;
  bool explicit_sid = false;
  bool explicit_jti = false;
  int interval_ms = 200;

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    auto take = [&](std::string& target) -> bool {
      if (i + 1 >= argc) {
        return false;
      }
      target = argv[++i];
      return true;
    };
    if (arg == "--addr") {
      if (!take(addr)) {
        usage();
        return 2;
      }
    } else if (arg == "--sub") {
      if (!take(sub)) {
        usage();
        return 2;
      }
      explicit_sub = true;
    } else if (arg == "--sid") {
      if (!take(sid)) {
        usage();
        return 2;
      }
      explicit_sid = true;
    } else if (arg == "--jti") {
      if (!take(jti)) {
        usage();
        return 2;
      }
      explicit_jti = true;
    } else if (arg == "--bearer-token") {
      if (!take(bearer_token)) {
        usage();
        return 2;
      }
    } else if (arg == "--interval") {
      std::string raw;
      if (!take(raw)) {
        usage();
        return 2;
      }
      if (raw.ends_with("ms")) {
        raw.resize(raw.size() - 2);
      }
      interval_ms = std::stoi(raw);
    } else {
      usage();
      return 2;
    }
  }

  auto channel = grpc::CreateChannel(addr, grpc::InsecureChannelCredentials());
  auto stub = reactive_mesh::demo::DemoService::NewStub(channel);

  grpc::ClientContext context;
  if (!bearer_token.empty()) {
    context.AddMetadata("authorization", "Bearer " + bearer_token);
  }
  if (explicit_sub || bearer_token.empty()) {
    context.AddMetadata("x-sub", sub);
  }
  if (explicit_sid) {
    context.AddMetadata("x-sid", sid);
  }
  if (explicit_jti) {
    context.AddMetadata("x-jti", jti);
  }

  reactive_mesh::demo::StreamRequest request;
  request.set_interval_ms(interval_ms);

  std::cerr << "grpc-client-cpp: connect addr=" << addr << " sub=" << (explicit_sub || bearer_token.empty() ? sub : "<jwt>")
            << " sid=" << (explicit_sid ? sid : "") << " jti=" << (explicit_jti ? jti : "")
            << " bearer=" << (!bearer_token.empty() ? "yes" : "no") << std::endl;

  auto reader = stub->Stream(&context, request);
  reactive_mesh::demo::StreamResponse response;
  while (reader->Read(&response)) {
    std::cout << response.body();
    std::cout.flush();
  }

  const grpc::Status status = reader->Finish();
  std::cerr << "grpc-client-cpp: stream ended code=" << status.error_code() << " msg=" << status.error_message()
            << std::endl;
  return status.ok() ? 0 : 1;
}
