#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <thread>

#include <google/protobuf/empty.pb.h>
#include <grpcpp/grpcpp.h>

#include "stream.grpc.pb.h"

namespace {

std::string getenvOr(const char* key, const char* fallback) {
  const char* value = std::getenv(key);
  return value == nullptr || *value == '\0' ? fallback : value;
}

std::string nowRfc3339Nano() {
  const auto now = std::chrono::system_clock::now();
  const auto secs = std::chrono::time_point_cast<std::chrono::seconds>(now);
  const auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(now - secs).count();
  const std::time_t tt = std::chrono::system_clock::to_time_t(now);
  std::tm tm{};
#if defined(_WIN32)
  gmtime_s(&tm, &tt);
#else
  gmtime_r(&tt, &tm);
#endif
  std::ostringstream out;
  out << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S") << '.' << std::setw(9) << std::setfill('0') << nanos << 'Z';
  return out.str();
}

std::string metadataValue(const grpc::ServerContext* ctx, const std::string& key) {
  const auto it = ctx->client_metadata().find(key);
  if (it == ctx->client_metadata().end()) {
    return "";
  }
  return std::string(it->second.data(), it->second.length());
}

class DemoServiceImpl final : public reactive_mesh::demo::DemoService::Service {
public:
  grpc::Status Stream(grpc::ServerContext* context, const reactive_mesh::demo::StreamRequest* request,
                      grpc::ServerWriter<reactive_mesh::demo::StreamResponse>* writer) override {
    const std::string sub = metadataValue(context, "x-sub");
    const std::string sid = metadataValue(context, "x-sid");
    const std::string jti = metadataValue(context, "x-jti");
    const auto interval = std::chrono::milliseconds(request->interval_ms() > 0 ? request->interval_ms() : 200);

    std::cerr << "grpc-server-cpp: new stream sub=" << sub << " sid=" << sid << " jti=" << jti << std::endl;

    uint64_t seq = 0;
    while (!context->IsCancelled()) {
      reactive_mesh::demo::StreamResponse response;
      response.set_body("sub=" + sub + " sid=" + sid + " jti=" + jti + " seq=" + std::to_string(++seq) +
                        " ts=" + nowRfc3339Nano() + "\n");
      if (!writer->Write(response)) {
        break;
      }
      std::this_thread::sleep_for(interval);
    }

    std::cerr << "grpc-server-cpp: stream closed sub=" << sub << " sid=" << sid << " jti=" << jti
              << " cancelled=" << context->IsCancelled() << std::endl;
    return grpc::Status::OK;
  }

  grpc::Status Ping(grpc::ServerContext*, const google::protobuf::Empty*, google::protobuf::Empty*) override {
    return grpc::Status::OK;
  }
};

} // namespace

int main() {
  const std::string listen_addr = getenvOr("LISTEN_ADDR", "0.0.0.0:50051");
  DemoServiceImpl service;

  grpc::ServerBuilder builder;
  builder.AddListeningPort(listen_addr, grpc::InsecureServerCredentials());
  builder.RegisterService(&service);
  std::unique_ptr<grpc::Server> server(builder.BuildAndStart());
  if (server == nullptr) {
    std::cerr << "grpc-server-cpp: failed to listen on " << listen_addr << std::endl;
    return 1;
  }

  std::cerr << "grpc-server-cpp: listening on " << listen_addr << std::endl;
  server->Wait();
  return 0;
}
