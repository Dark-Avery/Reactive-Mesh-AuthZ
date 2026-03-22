#include <memory>

#include "absl/status/status.h"
#include "envoy/registry/registry.h"
#include "envoy/server/filter_config.h"

#include "google/protobuf/struct.pb.h"

#include "reactive_pep/reactive_pep_filter.h"
#include "reactive_pep/reactive_pep_filter_config.h"

namespace Envoy {
namespace Extensions {
namespace HttpFilters {
namespace ReactivePep {

class ReactivePepFilterFactory : public Server::Configuration::NamedHttpFilterConfigFactory {
public:
  std::string name() const override { return "reactive_pep"; }

  ProtobufTypes::MessagePtr createEmptyConfigProto() override {
    return std::make_unique<google::protobuf::Struct>();
  }

  ProtobufTypes::MessagePtr createEmptyRouteConfigProto() override { return nullptr; }

private:
  absl::StatusOr<Http::FilterFactoryCb>
  createFilterFactoryFromProto(const Protobuf::Message& config, const std::string&,
                               Server::Configuration::FactoryContext& context) override {
    const auto* proto_config = dynamic_cast<const google::protobuf::Struct*>(&config);
    if (proto_config == nullptr) {
      return absl::InvalidArgumentError("reactive_pep expects google.protobuf.Struct config");
    }

    auto filter_config = std::make_shared<reactive_pep::FilterConfig>(*proto_config, context);
    return [filter_config](Http::FilterChainFactoryCallbacks& callbacks) {
      callbacks.addStreamDecoderFilter(
          std::make_shared<reactive_pep::ReactivePepFilter>(filter_config));
    };
  }

  absl::StatusOr<Router::RouteSpecificFilterConfigConstSharedPtr>
  createRouteSpecificFilterConfig(const Protobuf::Message&, Server::Configuration::ServerFactoryContext&,
                                  ProtobufMessage::ValidationVisitor&) override {
    return nullptr;
  }
};

REGISTER_FACTORY(ReactivePepFilterFactory, Server::Configuration::NamedHttpFilterConfigFactory);

} // namespace ReactivePep
} // namespace HttpFilters
} // namespace Extensions
} // namespace Envoy
