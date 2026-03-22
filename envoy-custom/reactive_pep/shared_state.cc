#include "reactive_pep/shared_state.h"

#include <utility>

#include "absl/strings/str_format.h"
#include "envoy/http/filter.h"
#include "source/common/common/logger.h"
#include "source/common/json/json_loader.h"

#include "reactive_pep/compat.h"
#include "reactive_pep/reactive_pep_filter_config.h"

namespace reactive_pep {

namespace {
// Best-effort extraction of string field from Envoy JSON object.
std::string getStringField(const Envoy::Json::ObjectSharedPtr& obj, const std::string& key) {
  try {
    return loadJsonStringResultCompat(obj->getString(key));
  } catch (...) {
    return "";
  }
}

std::vector<std::string> identitiesFromEvent(const Envoy::Json::ObjectSharedPtr& obj) {
  std::vector<std::string> ids;
  const std::string sub = getStringField(obj, "sub");
  const std::string sid = getStringField(obj, "sid");
  const std::string jti = getStringField(obj, "jti");
  if (!sub.empty()) {
    ids.push_back("sub:" + sub);
  }
  if (!sid.empty()) {
    ids.push_back("sid:" + sid);
  }
  if (!jti.empty()) {
    ids.push_back("jti:" + jti);
  }
  return ids;
}
} // namespace

bool SharedState::isRevokedAny(const std::vector<std::string>& identities) const {
  absl::MutexLock lock(&mu_);
  for (const auto& identity : identities) {
    if (revoked_identities_.contains(identity)) {
      return true;
    }
  }
  return false;
}

void SharedState::revokeIdentities(const std::vector<std::string>& identities) {
  absl::MutexLock lock(&mu_);
  for (const auto& identity : identities) {
    revoked_identities_.insert(identity);
  }
}

uint64_t SharedState::registerStream(const std::vector<std::string>& identities,
                                     Envoy::Event::Dispatcher& dispatcher,
                                     Envoy::Http::StreamDecoderFilterCallbacks& callbacks) {
  auto s = std::make_shared<ActiveStream>();
  s->id = next_stream_id_.fetch_add(1);
  s->identities = identities;
  s->dispatcher = &dispatcher;
  s->callbacks = &callbacks;

  absl::MutexLock lock(&mu_);
  streams_by_id_[s->id] = s;
  for (const auto& identity : identities) {
    ids_by_identity_[identity].insert(s->id);
  }
  if (stats_ != nullptr) {
    stats_->stats_.active_streams_.inc();
  }
  return s->id;
}

void SharedState::unregisterStream(uint64_t id) {
  absl::MutexLock lock(&mu_);
  auto it = streams_by_id_.find(id);
  if (it == streams_by_id_.end()) {
    return;
  }
  const std::vector<std::string> identities = it->second->identities;
  streams_by_id_.erase(it);
  if (stats_ != nullptr) {
    stats_->stats_.active_streams_.dec();
  }

  for (const auto& identity : identities) {
    auto sit = ids_by_identity_.find(identity);
    if (sit != ids_by_identity_.end()) {
      sit->second.erase(id);
      if (sit->second.empty()) {
        ids_by_identity_.erase(sit);
      }
    }
  }
}

void SharedState::resetStreamsForIdentities(const std::vector<std::string>& identities, const std::string& reason) {
  std::vector<std::weak_ptr<ActiveStream>> targets;
  {
    absl::MutexLock lock(&mu_);
    absl::flat_hash_set<uint64_t> unique_ids;
    for (const auto& identity : identities) {
      auto it = ids_by_identity_.find(identity);
      if (it == ids_by_identity_.end()) {
        continue;
      }
      unique_ids.insert(it->second.begin(), it->second.end());
    }

    targets.reserve(unique_ids.size());
    for (const uint64_t id : unique_ids) {
      auto sit = streams_by_id_.find(id);
      if (sit != streams_by_id_.end()) {
        targets.emplace_back(sit->second);
      }
    }
  }

  if (stats_ != nullptr && !targets.empty()) {
    stats_->stats_.pep_termination_total_.add(targets.size());
  }
  for (auto& weak : targets) {
    if (auto s = weak.lock()) {
      // Schedule reset on the owning dispatcher thread.
      s->dispatcher->post([weak, reason]() {
        if (auto ss = weak.lock()) {
          resetStreamCompat(ss->callbacks, Envoy::Http::StreamResetReason::LocalReset, reason);
        }
      });
    }
  }
}

void SharedState::handleEventJson(const std::string& json) {
  // Parse event JSON and extract matching identifiers. Ignore unknown fields.
  const Envoy::Json::ObjectSharedPtr obj = loadJsonObjectCompat(json);
  if (obj == nullptr) {
    return;
  }
  const std::string event_type = getStringField(obj, "event_type");
  if (event_type != "session_revoked" && event_type != "session-revoked" &&
      event_type != "risk_deny" && event_type != "risk-deny") {
    return;
  }
  const std::vector<std::string> identities = identitiesFromEvent(obj);
  if (identities.empty()) {
    return;
  }

  revokeIdentities(identities);

  if (logEvents()) {
    ENVOY_LOG_MISC(info, "reactive_pep: revoke matched identifiers count={} json={}", identities.size(), json);
  }
  resetStreamsForIdentities(identities, "reactive_pep_revoked");
}

} // namespace reactive_pep
