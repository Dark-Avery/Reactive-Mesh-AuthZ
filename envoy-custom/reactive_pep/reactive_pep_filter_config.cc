#include "reactive_pep/reactive_pep_filter_config.h"

#include <mutex>
#include <utility>

#include "absl/strings/str_format.h"
#include "source/common/common/logger.h"

#include "reactive_pep/redis_pubsub.h"

namespace reactive_pep {

namespace {

SharedStatePtr sharedStateSingleton() {
  static SharedStatePtr s = std::make_shared<SharedState>();
  return s;
}

ReactivePepStatsBundleSharedPtr statsSingleton(Envoy::Server::Configuration::FactoryContext& context) {
  static ReactivePepStatsBundleSharedPtr s = [](
                                                 Envoy::Server::Configuration::FactoryContext& ctx) {
    auto& server_ctx = ctx.serverFactoryContext();
    server_ctx.api().customStatNamespaces().registerStatNamespace("reactive_pep");
    return std::make_shared<ReactivePepStatsBundle>(server_ctx.serverScope());
  }(context);
  return s;
}

std::string getString(const google::protobuf::Struct& st, const std::string& key, const std::string& def) {
  const auto& m = st.fields();
  auto it = m.find(key);
  if (it == m.end()) {
    return def;
  }
  const auto& v = it->second;
  if (v.kind_case() == google::protobuf::Value::kStringValue) {
    return v.string_value();
  }
  return def;
}

uint32_t getUint32(const google::protobuf::Struct& st, const std::string& key, uint32_t def) {
  const auto& m = st.fields();
  auto it = m.find(key);
  if (it == m.end()) {
    return def;
  }
  const auto& v = it->second;
  if (v.kind_case() == google::protobuf::Value::kNumberValue) {
    const double d = v.number_value();
    if (d < 0) {
      return def;
    }
    if (d > 4294967295.0) {
      return def;
    }
    return static_cast<uint32_t>(d);
  }
  return def;
}

uint16_t getUint16(const google::protobuf::Struct& st, const std::string& key, uint16_t def) {
  const uint32_t v = getUint32(st, key, def);
  if (v > 65535) {
    return def;
  }
  return static_cast<uint16_t>(v);
}

bool getBool(const google::protobuf::Struct& st, const std::string& key, bool def) {
  const auto& m = st.fields();
  auto it = m.find(key);
  if (it == m.end()) {
    return def;
  }
  const auto& v = it->second;
  if (v.kind_case() == google::protobuf::Value::kBoolValue) {
    return v.bool_value();
  }
  return def;
}

struct GlobalSubscriber {
  std::once_flag once;
  std::unique_ptr<RedisPubSubSubscriber> sub;
};

GlobalSubscriber& globalSubscriber() {
  static GlobalSubscriber g;
  return g;
}

void ensureSubscriberStarted(const std::string& host, uint16_t port, const std::string& channel,
                             const SharedStatePtr& state, bool log_events) {
  auto& g = globalSubscriber();
  std::call_once(g.once, [&]() {
    state->setLogEvents(log_events);

    g.sub = std::make_unique<RedisPubSubSubscriber>(
        host, port, channel, [state](const std::string& payload) { state->handleEventJson(payload); });

    ENVOY_LOG_MISC(info, "reactive_pep: starting Redis subscriber host={} port={} channel={}", host, port, channel);
    g.sub->start();
  });
}

} // namespace

FilterConfig::FilterConfig(const google::protobuf::Struct& cfg_struct,
                           Envoy::Server::Configuration::FactoryContext& context) {
  shared_state_ = sharedStateSingleton();
  stats_ = statsSingleton(context);
  shared_state_->setStats(stats_);

  // Parse config
  redis_host_ = getString(cfg_struct, "redis_host", redis_host_);
  redis_port_ = getUint16(cfg_struct, "redis_port", redis_port_);
  redis_channel_ = getString(cfg_struct, "redis_channel", redis_channel_);
  subject_header_ = getString(cfg_struct, "subject_header", subject_header_);
  session_header_ = getString(cfg_struct, "session_header", session_header_);
  token_header_ = getString(cfg_struct, "token_header", token_header_);
  block_status_ = getUint32(cfg_struct, "block_status", block_status_);
  log_events_ = getBool(cfg_struct, "log_events", log_events_);

  // Start background Redis subscriber once per process
  ensureSubscriberStarted(redis_host_, redis_port_, redis_channel_, shared_state_, log_events_);
}

} // namespace reactive_pep
