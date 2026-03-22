#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

#include "absl/container/flat_hash_map.h"
#include "absl/container/flat_hash_set.h"
#include "absl/synchronization/mutex.h"

namespace Envoy {
namespace Http {
class StreamDecoderFilterCallbacks;
enum class StreamResetReason;
} // namespace Http
namespace Event {
class Dispatcher;
} // namespace Event
} // namespace Envoy

namespace reactive_pep {

struct ReactivePepStatsBundle;
using ReactivePepStatsBundleSharedPtr = std::shared_ptr<ReactivePepStatsBundle>;

// One active downstream stream (per request) tracked for a given subject.
struct ActiveStream {
  uint64_t id;
  std::vector<std::string> identities;

  // Owned by the stream's thread; only accessed via dispatcher.post().
  Envoy::Event::Dispatcher* dispatcher{nullptr};
  Envoy::Http::StreamDecoderFilterCallbacks* callbacks{nullptr};
};

class SharedState {
public:
  SharedState() = default;

  // Revocation cache
  bool isRevokedAny(const std::vector<std::string>& identities) const;
  void revokeIdentities(const std::vector<std::string>& identities);

  // Active stream tracking
  uint64_t registerStream(const std::vector<std::string>& identities,
                          Envoy::Event::Dispatcher& dispatcher,
                          Envoy::Http::StreamDecoderFilterCallbacks& callbacks);
  void unregisterStream(uint64_t id);

  // Reactive: reset all currently active streams matching any revoked identity.
  void resetStreamsForIdentities(const std::vector<std::string>& identities, const std::string& reason);

  // Internals: called by Redis subscriber on message
  void handleEventJson(const std::string& json);

  // Optional logging
  void setLogEvents(bool v) { log_events_.store(v); }
  bool logEvents() const { return log_events_.load(); }
  void setStats(const ReactivePepStatsBundleSharedPtr& stats) { stats_ = stats; }

private:
  mutable absl::Mutex mu_;

  // revoked identifiers in the form "sub:<value>", "sid:<value>", "jti:<value>"
  absl::flat_hash_set<std::string> revoked_identities_ ABSL_GUARDED_BY(mu_);

  // stream tracking
  std::atomic<uint64_t> next_stream_id_{1};
  absl::flat_hash_map<uint64_t, std::shared_ptr<ActiveStream>> streams_by_id_ ABSL_GUARDED_BY(mu_);
  absl::flat_hash_map<std::string, absl::flat_hash_set<uint64_t>> ids_by_identity_ ABSL_GUARDED_BY(mu_);

  std::atomic<bool> log_events_{false};
  ReactivePepStatsBundleSharedPtr stats_;
};

using SharedStatePtr = std::shared_ptr<SharedState>;

} // namespace reactive_pep
