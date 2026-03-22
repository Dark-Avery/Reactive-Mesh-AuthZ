#pragma once

#include <string>

#include "source/common/common/logger.h"
#include "source/extensions/filters/http/common/pass_through_filter.h"

#include "reactive_pep/reactive_pep_filter_config.h"

namespace reactive_pep {

class ReactivePepFilter : public Envoy::Http::PassThroughDecoderFilter,
                          public Envoy::Logger::Loggable<Envoy::Logger::Id::filter> {
public:
  explicit ReactivePepFilter(const FilterConfigSharedPtr& config);

  Envoy::Http::FilterHeadersStatus decodeHeaders(Envoy::Http::RequestHeaderMap& headers,
                                                 bool end_stream) override;

  void onDestroy() override;

private:
  const FilterConfigSharedPtr config_;
  std::vector<std::string> identities_;
  uint64_t stream_id_{0};
  bool registered_{false};
};

} // namespace reactive_pep
