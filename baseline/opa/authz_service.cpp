#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "common/cpp/json_utils.h"
#include "common/cpp/simple_http.h"
#include "common/cpp/simple_redis.h"
#include "common/cpp/simple_redis_pubsub.h"

namespace {

struct Config {
  std::string listen_addr{"0.0.0.0:9191"};
  std::string redis_addr{"redis:6379"};
  std::string redis_channel{"auth_events"};
  std::string mode{"direct"};
  int poll_interval_ms{1000};
  int push_ttl_seconds{3600};
  std::string openfga_addr{"openfga:8080"};
  std::string openfga_policy_user{"user:policy"};
  std::string spicedb_addr{"spicedb:8443"};
  std::string spicedb_preshared_key{"reactive-mesh-token"};
  std::string spicedb_policy_subject{"user:policy"};
};

struct Metrics {
  std::atomic<uint64_t> authorize_requests_total{0};
  std::atomic<uint64_t> authorize_denies_total{0};
  std::atomic<uint64_t> authorize_cache_hits_total{0};
  std::atomic<uint64_t> authorize_refresh_total{0};
};

struct CacheEntry {
  bool denied{false};
  std::chrono::steady_clock::time_point expires_at{};
};

using TimePoint = std::chrono::steady_clock::time_point;

std::string getenvOr(const char* key, const char* fallback) {
  const char* value = std::getenv(key);
  return value == nullptr || *value == '\0' ? fallback : value;
}

int getenvInt(const char* key, int fallback) {
  const char* value = std::getenv(key);
  if (value == nullptr || *value == '\0') {
    return fallback;
  }
  try {
    return std::stoi(value);
  } catch (...) {
    return fallback;
  }
}

std::string denyKey(const std::string& kind, const std::string& value) {
  return "deny:" + kind + ":" + value;
}

std::string openFgaObjectFor(const std::string& kind, const std::string& value) {
  if (kind == "sub") {
    return "subject:" + value;
  }
  if (kind == "sid") {
    return "session:" + value;
  }
  return "token:" + value;
}

std::string spiceDbObjectTypeFor(const std::string& kind) {
  if (kind == "sub") {
    return "subject";
  }
  if (kind == "sid") {
    return "session";
  }
  return "token";
}

bool splitObjectRef(const std::string& value, std::string& object_type, std::string& object_id) {
  const size_t colon = value.find(':');
  if (colon == std::string::npos || colon == 0 || colon + 1 >= value.size()) {
    return false;
  }
  object_type = value.substr(0, colon);
  object_id = value.substr(colon + 1);
  return true;
}

std::string identityCacheKey(const std::vector<std::pair<std::string, std::string>>& ids) {
  std::ostringstream out;
  for (const auto& [kind, value] : ids) {
    out << kind << '=' << value << '|';
  }
  return out.str();
}

std::string singleIdentifierKey(const std::string& kind, const std::string& value) {
  return kind + ":" + value;
}

std::vector<std::string> splitCompact(const std::string& value, char ch) {
  std::vector<std::string> parts;
  std::string current;
  for (const char c : value) {
    if (c == ch) {
      parts.push_back(current);
      current.clear();
      continue;
    }
    current.push_back(c);
  }
  parts.push_back(current);
  return parts;
}

std::optional<std::string> base64UrlDecode(const std::string& input) {
  std::string normalized = input;
  for (char& ch : normalized) {
    if (ch == '-') {
      ch = '+';
    } else if (ch == '_') {
      ch = '/';
    }
  }
  while (normalized.size() % 4 != 0) {
    normalized.push_back('=');
  }

  auto decode_char = [](char ch) -> int {
    if (ch >= 'A' && ch <= 'Z') {
      return ch - 'A';
    }
    if (ch >= 'a' && ch <= 'z') {
      return ch - 'a' + 26;
    }
    if (ch >= '0' && ch <= '9') {
      return ch - '0' + 52;
    }
    if (ch == '+') {
      return 62;
    }
    if (ch == '/') {
      return 63;
    }
    if (ch == '=') {
      return -2;
    }
    return -1;
  };

  std::string out;
  out.reserve((normalized.size() * 3) / 4);
  for (size_t i = 0; i < normalized.size(); i += 4) {
    const int a = decode_char(normalized[i]);
    const int b = decode_char(normalized[i + 1]);
    const int c = decode_char(normalized[i + 2]);
    const int d = decode_char(normalized[i + 3]);
    if (a < 0 || b < 0 || c == -1 || d == -1) {
      return std::nullopt;
    }

    const uint32_t triple = (static_cast<uint32_t>(a) << 18) | (static_cast<uint32_t>(b) << 12) |
                            (static_cast<uint32_t>(c < 0 ? 0 : c) << 6) | static_cast<uint32_t>(d < 0 ? 0 : d);
    out.push_back(static_cast<char>((triple >> 16) & 0xFF));
    if (c != -2) {
      out.push_back(static_cast<char>((triple >> 8) & 0xFF));
    }
    if (d != -2) {
      out.push_back(static_cast<char>(triple & 0xFF));
    }
  }
  return out;
}

std::optional<std::string> bearerTokenPayload(const reactive_mesh::http::Request& request) {
  const auto it = request.headers.find("authorization");
  if (it == request.headers.end()) {
    return std::nullopt;
  }
  const std::string prefix = "Bearer ";
  if (it->second.size() <= prefix.size() || it->second.substr(0, prefix.size()) != prefix) {
    return std::nullopt;
  }
  const auto parts = splitCompact(it->second.substr(prefix.size()), '.');
  if (parts.size() != 3) {
    return std::nullopt;
  }
  return base64UrlDecode(parts[1]);
}

std::vector<std::pair<std::string, std::string>> identifiersFromPublishedEvent(const std::string& payload) {
  std::vector<std::pair<std::string, std::string>> ids;
  if (const auto sub = reactive_mesh::json::extractString(payload, "sub"); sub.has_value() && !sub->empty()) {
    ids.emplace_back("sub", *sub);
  }
  if (const auto sid = reactive_mesh::json::extractString(payload, "sid"); sid.has_value() && !sid->empty()) {
    ids.emplace_back("sid", *sid);
  }
  if (const auto jti = reactive_mesh::json::extractString(payload, "jti"); jti.has_value() && !jti->empty()) {
    ids.emplace_back("jti", *jti);
  }
  return ids;
}

std::vector<std::pair<std::string, std::string>> collectIdentifiers(const reactive_mesh::http::Request& request) {
  std::vector<std::pair<std::string, std::string>> ids;
  const auto pick = [&](const std::string& query_key, const std::string& header_key, const std::string& kind) {
    auto it = request.query.find(query_key);
    if (it != request.query.end() && !it->second.empty()) {
      ids.emplace_back(kind, it->second);
      return;
    }
    auto hit = request.headers.find(header_key);
    if (hit != request.headers.end() && !hit->second.empty()) {
      ids.emplace_back(kind, hit->second);
    }
  };
  pick("sub", "x-sub", "sub");
  pick("sid", "x-sid", "sid");
  pick("jti", "x-jti", "jti");
  if (ids.size() < 3) {
    if (const auto payload = bearerTokenPayload(request); payload.has_value()) {
      const auto add_if_missing = [&](const std::string& kind) {
        const bool present = std::any_of(ids.begin(), ids.end(), [&](const auto& item) { return item.first == kind; });
        if (present) {
          return;
        }
        if (const auto value = reactive_mesh::json::extractString(*payload, kind); value.has_value() && !value->empty()) {
          ids.emplace_back(kind, *value);
        }
      };
      add_if_missing("sub");
      add_if_missing("sid");
      add_if_missing("jti");
    }
  }
  return ids;
}

bool queryRedisDecision(const reactive_mesh::redis::Client& redis, const std::vector<std::pair<std::string, std::string>>& ids,
                        std::vector<std::string>& matched) {
  matched.clear();
  for (const auto& [kind, value] : ids) {
    bool present = false;
    if (!redis.exists(denyKey(kind, value), present)) {
      return false;
    }
    if (present) {
      matched.push_back(kind + ":" + value);
    }
  }
  return true;
}

bool loadOpenFgaMetadata(const reactive_mesh::redis::Client& redis, std::string& store_id, std::string& model_id) {
  std::optional<std::string> store;
  std::optional<std::string> model;
  if (!redis.get("openfga:store_id", store) || !redis.get("openfga:model_id", model)) {
    return false;
  }
  if (!store.has_value() || !model.has_value() || store->empty() || model->empty()) {
    return false;
  }
  store_id = *store;
  model_id = *model;
  return true;
}

bool queryOpenFgaDecision(const reactive_mesh::redis::Client& redis, const Config& config,
                          const std::vector<std::pair<std::string, std::string>>& ids, std::vector<std::string>& matched) {
  matched.clear();
  std::string store_id;
  std::string model_id;
  if (!loadOpenFgaMetadata(redis, store_id, model_id)) {
    return false;
  }

  for (const auto& [kind, value] : ids) {
    const std::string body = std::string("{\"tuple_key\":{\"user\":\"") +
                             reactive_mesh::json::escape(config.openfga_policy_user) +
                             "\",\"relation\":\"revoked\",\"object\":\"" +
                             reactive_mesh::json::escape(openFgaObjectFor(kind, value)) +
                             "\"},\"authorization_model_id\":\"" + reactive_mesh::json::escape(model_id) + "\"}";
    reactive_mesh::http::ClientResponse response;
    const std::string path = "/stores/" + store_id + "/check";
    if (!reactive_mesh::http::request(config.openfga_addr, "POST", path, body,
                                      {{"Content-Type", "application/json"}}, response)) {
      return false;
    }
    if (response.status < 200 || response.status >= 300) {
      return false;
    }
    if (response.body.find("\"allowed\":true") != std::string::npos) {
      matched.push_back(kind + ":" + value);
    }
  }
  return true;
}

bool querySpiceDbDecision(const Config& config, const std::vector<std::pair<std::string, std::string>>& ids,
                          std::vector<std::string>& matched) {
  matched.clear();
  std::string subject_type;
  std::string subject_id;
  if (!splitObjectRef(config.spicedb_policy_subject, subject_type, subject_id)) {
    return false;
  }

  for (const auto& [kind, value] : ids) {
    const std::string body =
        std::string("{\"consistency\":{\"minimizeLatency\":true},\"resource\":{\"objectType\":\"") +
        reactive_mesh::json::escape(spiceDbObjectTypeFor(kind)) + "\",\"objectId\":\"" +
        reactive_mesh::json::escape(value) + "\"},\"permission\":\"denied\",\"subject\":{\"object\":{\"objectType\":\"" +
        reactive_mesh::json::escape(subject_type) + "\",\"objectId\":\"" + reactive_mesh::json::escape(subject_id) +
        "\"}}}";
    reactive_mesh::http::ClientResponse response;
    if (!reactive_mesh::http::request(config.spicedb_addr, "POST", "/v1/permissions/check", body,
                                      {{"Content-Type", "application/json"},
                                       {"Authorization", "Bearer " + config.spicedb_preshared_key}},
                                      response)) {
      return false;
    }
    if (response.status < 200 || response.status >= 300) {
      return false;
    }
    if (response.body.find("PERMISSIONSHIP_HAS_PERMISSION") != std::string::npos) {
      matched.push_back(kind + ":" + value);
    }
  }
  return true;
}

std::string metricsBody(const Metrics& metrics) {
  std::ostringstream out;
  out << "authorize_requests_total " << metrics.authorize_requests_total.load() << '\n';
  out << "authorize_denies_total " << metrics.authorize_denies_total.load() << '\n';
  out << "authorize_cache_hits_total " << metrics.authorize_cache_hits_total.load() << '\n';
  out << "authorize_refresh_total " << metrics.authorize_refresh_total.load() << '\n';
  return out.str();
}

reactive_mesh::http::Response jsonError(int status, const std::string& message) {
  reactive_mesh::http::Response response;
  response.status = status;
  response.body = "{\"error\":\"" + reactive_mesh::json::escape(message) + "\"}";
  return response;
}

} // namespace

int main() {
  const Config config{
      .listen_addr = getenvOr("LISTEN_ADDR", "0.0.0.0:9191"),
      .redis_addr = getenvOr("REDIS_ADDR", "redis:6379"),
      .redis_channel = getenvOr("REDIS_CHANNEL", "auth_events"),
      .mode = getenvOr("BASELINE_MODE", "direct"),
      .poll_interval_ms = getenvInt("POLL_INTERVAL_MS", 1000),
      .push_ttl_seconds = getenvInt("PUSH_TTL_SECONDS", 3600),
      .openfga_addr = getenvOr("OPENFGA_ADDR", "openfga:8080"),
      .openfga_policy_user = getenvOr("OPENFGA_POLICY_USER", "user:policy"),
      .spicedb_addr = getenvOr("SPICEDB_ADDR", "spicedb:8443"),
      .spicedb_preshared_key = getenvOr("SPICEDB_PRESHARED_KEY", "reactive-mesh-token"),
      .spicedb_policy_subject = getenvOr("SPICEDB_POLICY_SUBJECT", "user:policy"),
  };
  Metrics metrics;
  std::mutex cache_mu;
  std::unordered_map<std::string, CacheEntry> cache;
  std::unordered_map<std::string, TimePoint> push_denies;
  const reactive_mesh::redis::Client redis(config.redis_addr);
  std::unique_ptr<reactive_mesh::redis::PubSubSubscriber> push_subscriber;

  if (config.mode == "push") {
    push_subscriber = std::make_unique<reactive_mesh::redis::PubSubSubscriber>(
        config.redis_addr, config.redis_channel, [&](const std::string& payload) {
          const auto ids = identifiersFromPublishedEvent(payload);
          if (ids.empty()) {
            return;
          }
          const auto expires_at = std::chrono::steady_clock::now() + std::chrono::seconds(config.push_ttl_seconds);
          std::lock_guard<std::mutex> lock(cache_mu);
          for (const auto& [kind, value] : ids) {
            push_denies[singleIdentifierKey(kind, value)] = expires_at;
          }
          metrics.authorize_refresh_total.fetch_add(1);
        });
    push_subscriber->start();
  }

  std::cerr << "baseline-authz-cpp: listen=" << config.listen_addr << " redis=" << config.redis_addr
            << " mode=" << config.mode << std::endl;

  reactive_mesh::http::serve(config.listen_addr, [&](const reactive_mesh::http::Request& request) {
    if (request.path == "/health") {
      return reactive_mesh::http::Response{.status = 200, .content_type = "application/json", .body = "{\"ok\":true}"};
    }
    if (request.path == "/metrics") {
      return reactive_mesh::http::Response{.status = 200, .content_type = "text/plain; version=0.0.4",
                                           .body = metricsBody(metrics)};
    }
    metrics.authorize_requests_total.fetch_add(1);
    const auto ids = collectIdentifiers(request);
    if (ids.empty()) {
      return reactive_mesh::http::Response{.status = 200, .content_type = "application/json",
                                           .body = "{\"allowed\":true,\"source\":\"no-identifiers\"}"};
    }

    const auto now = std::chrono::steady_clock::now();
    const auto key = identityCacheKey(ids);

    std::vector<std::string> matched;
    bool denied = false;
    std::string source = "redis";

    if (config.mode == "poll") {
      std::lock_guard<std::mutex> lock(cache_mu);
      auto it = cache.find(key);
      if (it != cache.end() && it->second.expires_at > now) {
        metrics.authorize_cache_hits_total.fetch_add(1);
        denied = it->second.denied;
        source = "cache";
      } else {
        if (!queryRedisDecision(redis, ids, matched)) {
          return jsonError(502, "redis exists failed");
        }
        denied = !matched.empty();
        cache[key] = CacheEntry{
            .denied = denied,
            .expires_at = now + std::chrono::milliseconds(config.poll_interval_ms),
        };
        metrics.authorize_refresh_total.fetch_add(1);
      }
    } else if (config.mode == "push") {
      {
        std::lock_guard<std::mutex> lock(cache_mu);
        for (auto it = push_denies.begin(); it != push_denies.end();) {
          if (it->second <= now) {
            it = push_denies.erase(it);
          } else {
            ++it;
          }
        }
        for (const auto& [kind, value] : ids) {
          const auto cached = push_denies.find(singleIdentifierKey(kind, value));
          if (cached != push_denies.end()) {
            matched.push_back(kind + ":" + value);
          }
        }
      }
      denied = !matched.empty();
      source = "push-cache";
      metrics.authorize_cache_hits_total.fetch_add(1);
    } else if (config.mode == "openfga") {
      if (!queryOpenFgaDecision(redis, config, ids, matched)) {
        return jsonError(502, "openfga check failed");
      }
      denied = !matched.empty();
      source = "openfga";
    } else if (config.mode == "spicedb") {
      if (!querySpiceDbDecision(config, ids, matched)) {
        return jsonError(502, "spicedb check failed");
      }
      denied = !matched.empty();
      source = "spicedb";
    } else {
      if (!queryRedisDecision(redis, ids, matched)) {
        return jsonError(502, "redis exists failed");
      }
      denied = !matched.empty();
    }

    if (denied) {
      metrics.authorize_denies_total.fetch_add(1);
    }

    reactive_mesh::http::Response response;
    response.status = denied ? 403 : 200;
    response.body = std::string("{\"allowed\":") + (denied ? "false" : "true") + ",\"source\":\"" +
                    reactive_mesh::json::escape(source) + "\",\"matched\":" +
                    reactive_mesh::json::stringArray(matched) + "}";
    return response;
  });
}
