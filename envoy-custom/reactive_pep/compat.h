#pragma once

#include <type_traits>
#include <utility>

#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "envoy/http/filter.h"
#include "source/common/json/json_loader.h"

namespace reactive_pep {

// Detect resetStream(StreamResetReason, absl::string_view)
template <class T>
class HasResetStreamWithReason {
private:
  template <class U>
  static auto test(int) -> decltype(std::declval<U>().resetStream(
                                        std::declval<Envoy::Http::StreamResetReason>(),
                                        std::declval<absl::string_view>()),
                                    std::true_type{});

  template <class>
  static auto test(...) -> std::false_type;

public:
  static constexpr bool value = decltype(test<T>(0))::value;
};

template <class Callbacks>
inline void resetStreamCompat(Callbacks* cb, Envoy::Http::StreamResetReason reason,
                              absl::string_view details) {
  if (cb == nullptr) {
    return;
  }
  if constexpr (HasResetStreamWithReason<Callbacks>::value) {
    cb->resetStream(reason, details);
  } else {
    cb->resetStream();
  }
}

inline Envoy::Json::ObjectSharedPtr loadJsonObjectResultCompat(Envoy::Json::ObjectSharedPtr obj) {
  return obj;
}

template <class T>
inline Envoy::Json::ObjectSharedPtr loadJsonObjectResultCompat(const absl::StatusOr<T>& result) {
  if (!result.ok()) {
    return nullptr;
  }
  return *result;
}

inline Envoy::Json::ObjectSharedPtr loadJsonObjectCompat(absl::string_view json) {
  return loadJsonObjectResultCompat(Envoy::Json::Factory::loadFromString(std::string(json)));
}

inline std::string loadJsonStringResultCompat(const std::string& value) { return value; }

template <class T>
inline std::string loadJsonStringResultCompat(const absl::StatusOr<T>& result) {
  if (!result.ok()) {
    return "";
  }
  return *result;
}

} // namespace reactive_pep
