#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include "envoy/common/pure.h"
#include "envoy/server/filter_config.h"
#include "envoy/stats/scope.h"
#include "envoy/stats/stats.h"
#include "google/protobuf/struct.pb.h"

#include "reactive_pep/shared_state.h"

namespace reactive_pep {

struct ReactivePepStats {
  Envoy::Stats::Counter& post_revoke_deny_total_;
  Envoy::Stats::Counter& pep_termination_total_;
  Envoy::Stats::Gauge& active_streams_;
};

struct ReactivePepStatsBundle {
  explicit ReactivePepStatsBundle(Envoy::Stats::Scope& scope)
      : stats_({
            scope.counterFromString("reactive_pep.post_revoke_deny_total"),
            scope.counterFromString("reactive_pep.pep_termination_total"),
            scope.gaugeFromString("reactive_pep.active_streams",
                                  Envoy::Stats::Gauge::ImportMode::Accumulate),
        }) {}

  ReactivePepStats stats_;
};

using ReactivePepStatsBundleSharedPtr = std::shared_ptr<ReactivePepStatsBundle>;

class FilterConfig {
public:
  FilterConfig(const google::protobuf::Struct& cfg_struct, Envoy::Server::Configuration::FactoryContext& context);

  const std::string& subjectHeader() const { return subject_header_; }
  const std::string& sessionHeader() const { return session_header_; }
  const std::string& tokenHeader() const { return token_header_; }
  uint32_t blockStatus() const { return block_status_; }
  SharedStatePtr sharedState() const { return shared_state_; }
  ReactivePepStats& stats() const { return stats_->stats_; }

private:
  std::string subject_header_{"x-sub"};
  std::string session_header_{"x-sid"};
  std::string token_header_{"x-jti"};
  uint32_t block_status_{403};

  // Redis settings (used only on first config creation to start subscriber).
  std::string redis_host_{"redis"};
  uint16_t redis_port_{6379};
  std::string redis_channel_{"auth_events"};

  bool log_events_{false};

  SharedStatePtr shared_state_;
  ReactivePepStatsBundleSharedPtr stats_;
};

using FilterConfigSharedPtr = std::shared_ptr<FilterConfig>;

} // namespace reactive_pep
