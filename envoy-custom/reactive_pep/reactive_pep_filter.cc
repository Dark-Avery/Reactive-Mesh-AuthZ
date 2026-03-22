#include "reactive_pep/reactive_pep_filter.h"

#include "envoy/http/filter.h"
#include "envoy/http/header_map.h"
#include "source/common/common/logger.h"

#include "reactive_pep/compat.h"

namespace reactive_pep {

namespace {

std::string readHeader(Envoy::Http::RequestHeaderMap& headers, const std::string& name) {
  const auto values = headers.get(Envoy::Http::LowerCaseString(name));
  if (values.empty()) {
    return "";
  }
  return std::string(values[0]->value().getStringView());
}

std::vector<std::string> collectIdentities(const FilterConfigSharedPtr& config,
                                           Envoy::Http::RequestHeaderMap& headers) {
  std::vector<std::string> ids;
  const std::string subject = readHeader(headers, config->subjectHeader());
  const std::string session = readHeader(headers, config->sessionHeader());
  const std::string token = readHeader(headers, config->tokenHeader());

  if (!subject.empty()) {
    ids.push_back("sub:" + subject);
  }
  if (!session.empty()) {
    ids.push_back("sid:" + session);
  }
  if (!token.empty()) {
    ids.push_back("jti:" + token);
  }
  return ids;
}

} // namespace

ReactivePepFilter::ReactivePepFilter(const FilterConfigSharedPtr& config) : config_(config) {}

Envoy::Http::FilterHeadersStatus ReactivePepFilter::decodeHeaders(Envoy::Http::RequestHeaderMap& headers,
                                                                  bool /*end_stream*/) {
  identities_ = collectIdentities(config_, headers);
  if (identities_.empty()) {
    return Envoy::Http::FilterHeadersStatus::Continue;
  }

  if (config_->sharedState()->isRevokedAny(identities_)) {
    ENVOY_LOG(debug, "reactive_pep: blocking request due to revoked identity match");
    config_->stats().post_revoke_deny_total_.inc();

    // For maximum API compatibility across Envoy versions, we forcefully reset the stream here
    // (instead of sendLocalReply()). gRPC clients will observe a stream error.
    resetStreamCompat(decoder_callbacks_, Envoy::Http::StreamResetReason::LocalReset, "reactive_pep_revoked");
    return Envoy::Http::FilterHeadersStatus::StopIteration;
  }

  // Track this stream to be able to reset it on async revocation events.
  stream_id_ = config_->sharedState()->registerStream(identities_, decoder_callbacks_->dispatcher(), *decoder_callbacks_);
  registered_ = true;

  return Envoy::Http::FilterHeadersStatus::Continue;
}

void ReactivePepFilter::onDestroy() {
  if (registered_) {
    config_->sharedState()->unregisterStream(stream_id_);
    registered_ = false;
  }
}

} // namespace reactive_pep
