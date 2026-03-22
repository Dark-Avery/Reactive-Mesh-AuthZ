#include <array>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>

#include "common/cpp/json_utils.h"
#include "common/cpp/simple_http.h"
#include "common/cpp/simple_redis.h"

namespace {

struct Config {
  std::string listen_addr{"0.0.0.0:8080"};
  std::string redis_addr{"redis:6379"};
  std::string redis_channel{"auth_events"};
  int state_ttl_seconds{3600};
  int dedup_ttl_seconds{86400};
  std::string jose_hs256_secret{};
  bool require_signed{false};
  bool openfga_sync_enabled{false};
  std::string openfga_addr{"openfga:8080"};
  std::string openfga_store_name{"reactive-mesh-authz"};
  std::string openfga_policy_user{"user:policy"};
  bool spicedb_sync_enabled{false};
  std::string spicedb_addr{"spicedb:8443"};
  std::string spicedb_preshared_key{"reactive-mesh-token"};
  std::string spicedb_policy_subject{"user:policy"};
};

struct Metrics {
  std::atomic<uint64_t> receiver_events_total{0};
  std::atomic<uint64_t> receiver_validation_failures_total{0};
  std::atomic<uint64_t> receiver_duplicate_events_total{0};
  std::atomic<uint64_t> receiver_state_queries_total{0};
  std::atomic<uint64_t> receiver_openfga_writes_total{0};
  std::atomic<uint64_t> receiver_openfga_failures_total{0};
  std::atomic<uint64_t> receiver_spicedb_writes_total{0};
  std::atomic<uint64_t> receiver_spicedb_failures_total{0};
};

struct OpenFgaState {
  std::string store_id;
  std::string model_id;
};

struct Event {
  std::string event_id;
  std::string event_type;
  std::string sub;
  std::string sid;
  std::string jti;
  std::string reason;
  std::string ts;
  std::string validation_source{"plain-json"};
};

struct ParseResult {
  std::optional<Event> event;
  std::string error;
};

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

bool getenvBool(const char* key, bool fallback) {
  const char* value = std::getenv(key);
  if (value == nullptr || *value == '\0') {
    return fallback;
  }
  const std::string text = reactive_mesh::json::trim(value);
  return text == "1" || text == "true" || text == "TRUE" || text == "yes" || text == "YES";
}

std::string normalizeEventType(std::string event_type) {
  for (char& ch : event_type) {
    if (ch == '_') {
      ch = '-';
    }
  }
  if (event_type == "session-revoked" || event_type == "risk-deny") {
    return event_type;
  }
  return "";
}

std::vector<std::pair<std::string, std::string>> collectIdentifiers(const Event& event) {
  std::vector<std::pair<std::string, std::string>> ids;
  if (!event.sub.empty()) {
    ids.emplace_back("sub", event.sub);
  }
  if (!event.sid.empty()) {
    ids.emplace_back("sid", event.sid);
  }
  if (!event.jti.empty()) {
    ids.emplace_back("jti", event.jti);
  }
  return ids;
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

  std::string out((normalized.size() * 3) / 4 + 3, '\0');
  const int len =
      EVP_DecodeBlock(reinterpret_cast<unsigned char*>(out.data()),
                      reinterpret_cast<const unsigned char*>(normalized.data()), static_cast<int>(normalized.size()));
  if (len < 0) {
    return std::nullopt;
  }
  size_t pad = 0;
  if (!normalized.empty() && normalized.back() == '=') {
    pad++;
  }
  if (normalized.size() > 1 && normalized[normalized.size() - 2] == '=') {
    pad++;
  }
  out.resize(static_cast<size_t>(len) - pad);
  return out;
}

std::string base64UrlEncode(const unsigned char* data, size_t len) {
  std::string out(((len + 2) / 3) * 4, '\0');
  const int written = EVP_EncodeBlock(reinterpret_cast<unsigned char*>(out.data()), data, static_cast<int>(len));
  out.resize(static_cast<size_t>(written));
  while (!out.empty() && out.back() == '=') {
    out.pop_back();
  }
  for (char& ch : out) {
    if (ch == '+') {
      ch = '-';
    } else if (ch == '/') {
      ch = '_';
    }
  }
  return out;
}

bool secureEquals(const std::string& lhs, const std::string& rhs) {
  if (lhs.size() != rhs.size()) {
    return false;
  }
  return CRYPTO_memcmp(lhs.data(), rhs.data(), lhs.size()) == 0;
}

std::optional<std::string> compactTokenFromBody(const std::string& body) {
  const std::string trimmed = reactive_mesh::json::trim(body);
  if (trimmed.empty()) {
    return std::nullopt;
  }
  if (trimmed.front() == '{') {
    const auto set_value = reactive_mesh::json::extractString(trimmed, "set");
    if (set_value.has_value() && splitCompact(*set_value, '.').size() == 3) {
      return *set_value;
    }
    return std::nullopt;
  }
  if (splitCompact(trimmed, '.').size() == 3) {
    return trimmed;
  }
  return std::nullopt;
}

reactive_mesh::http::Response jsonError(int status, const std::string& message) {
  reactive_mesh::http::Response response;
  response.status = status;
  response.body = "{\"error\":\"" + reactive_mesh::json::escape(message) + "\"}";
  return response;
}

std::optional<Event> parsePlainEvent(const std::string& body) {
  Event event;
  if (const auto value = reactive_mesh::json::extractString(body, "event_id")) {
    event.event_id = *value;
  }
  if (const auto value = reactive_mesh::json::extractString(body, "event_type")) {
    event.event_type = normalizeEventType(*value);
  }
  if (const auto value = reactive_mesh::json::extractString(body, "sub")) {
    event.sub = *value;
  }
  if (const auto value = reactive_mesh::json::extractString(body, "sid")) {
    event.sid = *value;
  }
  if (const auto value = reactive_mesh::json::extractString(body, "jti")) {
    event.jti = *value;
  }
  if (const auto value = reactive_mesh::json::extractString(body, "reason")) {
    event.reason = *value;
  }
  if (const auto value = reactive_mesh::json::extractString(body, "ts")) {
    event.ts = *value;
  }

  if (event.event_type.empty()) {
    return std::nullopt;
  }
  if (event.event_id.empty()) {
    event.event_id = reactive_mesh::json::randomHexId();
  }
  if (event.ts.empty()) {
    event.ts = reactive_mesh::json::nowRfc3339Nano();
  }
  return event;
}

ParseResult parseSignedEvent(const std::string& token, const Config& config) {
  if (config.jose_hs256_secret.empty()) {
    return ParseResult{.error = "signed SET received but JOSE_HS256_SECRET is not configured"};
  }

  const auto parts = splitCompact(token, '.');
  if (parts.size() != 3) {
    return ParseResult{.error = "invalid compact JWS"};
  }

  const auto header_json = base64UrlDecode(parts[0]);
  const auto payload_json = base64UrlDecode(parts[1]);
  const auto signature = base64UrlDecode(parts[2]);
  if (!header_json.has_value() || !payload_json.has_value() || !signature.has_value()) {
    return ParseResult{.error = "invalid JWS base64url encoding"};
  }

  const auto alg = reactive_mesh::json::extractString(*header_json, "alg");
  if (!alg.has_value() || *alg != "HS256") {
    return ParseResult{.error = "unsupported JWS alg"};
  }

  unsigned int digest_len = 0;
  std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
  const std::string signing_input = parts[0] + "." + parts[1];
  if (HMAC(EVP_sha256(), config.jose_hs256_secret.data(), static_cast<int>(config.jose_hs256_secret.size()),
           reinterpret_cast<const unsigned char*>(signing_input.data()), signing_input.size(), digest.data(),
           &digest_len) == nullptr) {
    return ParseResult{.error = "HMAC verification failed"};
  }
  const std::string expected = base64UrlEncode(digest.data(), digest_len);
  if (!secureEquals(expected, parts[2])) {
    return ParseResult{.error = "invalid JWS signature"};
  }

  auto event = parsePlainEvent(*payload_json);
  if (!event.has_value()) {
    return ParseResult{.error = "signed payload is not a valid supported event"};
  }
  event->validation_source = "jose-hs256";
  return ParseResult{.event = std::move(event)};
}

ParseResult parseEvent(const std::string& body, const Config& config) {
  if (const auto token = compactTokenFromBody(body); token.has_value()) {
    return parseSignedEvent(*token, config);
  }
  if (config.require_signed) {
    return ParseResult{.error = "signed SET is required"};
  }
  auto event = parsePlainEvent(body);
  if (!event.has_value()) {
    return ParseResult{.error = "event_type must be session-revoked or risk-deny"};
  }
  event->validation_source = "plain-json";
  return ParseResult{.event = std::move(event)};
}

std::string metricsBody(const Metrics& metrics) {
  std::ostringstream out;
  out << "receiver_events_total " << metrics.receiver_events_total.load() << '\n';
  out << "receiver_validation_failures_total " << metrics.receiver_validation_failures_total.load() << '\n';
  out << "receiver_duplicate_events_total " << metrics.receiver_duplicate_events_total.load() << '\n';
  out << "receiver_state_queries_total " << metrics.receiver_state_queries_total.load() << '\n';
  out << "receiver_openfga_writes_total " << metrics.receiver_openfga_writes_total.load() << '\n';
  out << "receiver_openfga_failures_total " << metrics.receiver_openfga_failures_total.load() << '\n';
  out << "receiver_spicedb_writes_total " << metrics.receiver_spicedb_writes_total.load() << '\n';
  out << "receiver_spicedb_failures_total " << metrics.receiver_spicedb_failures_total.load() << '\n';
  return out.str();
}

bool openFgaCreateStore(const Config& config, OpenFgaState& state, std::string& error) {
  reactive_mesh::http::ClientResponse response;
  const std::string body = reactive_mesh::json::object({{"name", config.openfga_store_name}});
  if (!reactive_mesh::http::request(config.openfga_addr, "POST", "/stores", body,
                                    {{"Content-Type", "application/json"}}, response)) {
    error = "openfga create store request failed";
    return false;
  }
  if (response.status < 200 || response.status >= 300) {
    error = "openfga create store failed: " + std::to_string(response.status);
    return false;
  }
  const auto store_id = reactive_mesh::json::extractString(response.body, "id");
  if (!store_id.has_value() || store_id->empty()) {
    error = "openfga create store returned no id";
    return false;
  }
  state.store_id = *store_id;
  return true;
}

bool openFgaWriteModel(const Config& config, OpenFgaState& state, std::string& error) {
  reactive_mesh::http::ClientResponse response;
  const std::string body =
      "{\"schema_version\":\"1.1\",\"type_definitions\":["
      "{\"type\":\"user\"},"
      "{\"type\":\"subject\",\"relations\":{\"revoked\":{\"this\":{}}},\"metadata\":{\"relations\":{\"revoked\":{\"directly_related_user_types\":[{\"type\":\"user\"}]}}}},"
      "{\"type\":\"session\",\"relations\":{\"revoked\":{\"this\":{}}},\"metadata\":{\"relations\":{\"revoked\":{\"directly_related_user_types\":[{\"type\":\"user\"}]}}}},"
      "{\"type\":\"token\",\"relations\":{\"revoked\":{\"this\":{}}},\"metadata\":{\"relations\":{\"revoked\":{\"directly_related_user_types\":[{\"type\":\"user\"}]}}}}"
      "]}";
  const std::string path = "/stores/" + state.store_id + "/authorization-models";
  if (!reactive_mesh::http::request(config.openfga_addr, "POST", path, body,
                                    {{"Content-Type", "application/json"}}, response)) {
    error = "openfga write model request failed";
    return false;
  }
  if (response.status < 200 || response.status >= 300) {
    error = "openfga write model failed: " + std::to_string(response.status);
    return false;
  }
  const auto model_id = reactive_mesh::json::extractString(response.body, "authorization_model_id");
  if (!model_id.has_value() || model_id->empty()) {
    error = "openfga write model returned no id";
    return false;
  }
  state.model_id = *model_id;
  return true;
}

bool persistOpenFgaMetadata(const reactive_mesh::redis::Client& redis, const OpenFgaState& state, std::string& error) {
  if (state.store_id.empty() || state.model_id.empty()) {
    error = "openfga metadata is empty";
    return false;
  }
  if (!redis.set("openfga:store_id", state.store_id) || !redis.set("openfga:model_id", state.model_id)) {
    error = "failed to persist OpenFGA metadata in redis";
    return false;
  }
  return true;
}

bool initializeOpenFga(const Config& config, const reactive_mesh::redis::Client& redis, OpenFgaState& state,
                       std::string& error) {
  if (!config.openfga_sync_enabled) {
    return true;
  }
  for (int attempt = 1; attempt <= 30; ++attempt) {
    state = OpenFgaState{};
    if (openFgaCreateStore(config, state, error) && openFgaWriteModel(config, state, error) &&
        persistOpenFgaMetadata(redis, state, error)) {
      return true;
    }
    if (attempt != 30) {
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }
  }
  if (error.empty()) {
    error = "failed to persist OpenFGA metadata in redis";
  }
  return false;
}

bool openFgaWriteRevocations(const Config& config, const OpenFgaState& state,
                             const std::vector<std::pair<std::string, std::string>>& ids, std::string& error) {
  if (!config.openfga_sync_enabled) {
    return true;
  }
  std::ostringstream tuples;
  for (size_t i = 0; i < ids.size(); ++i) {
    const auto& [kind, value] = ids[i];
    if (i != 0) {
      tuples << ',';
    }
    tuples << "{\"user\":\"" << reactive_mesh::json::escape(config.openfga_policy_user)
           << "\",\"relation\":\"revoked\",\"object\":\""
           << reactive_mesh::json::escape(openFgaObjectFor(kind, value)) << "\"}";
  }
  const std::string body = std::string("{\"writes\":{\"tuple_keys\":[") + tuples.str() +
                           "]},\"authorization_model_id\":\"" + reactive_mesh::json::escape(state.model_id) + "\"}";
  reactive_mesh::http::ClientResponse response;
  const std::string path = "/stores/" + state.store_id + "/write";
  if (!reactive_mesh::http::request(config.openfga_addr, "POST", path, body,
                                    {{"Content-Type", "application/json"}}, response)) {
    error = "openfga write tuple request failed";
    return false;
  }
  if (response.status < 200 || response.status >= 300) {
    error = "openfga write tuple failed: " + std::to_string(response.status);
    return false;
  }
  return true;
}

bool initializeSpiceDb(const Config& config, std::string& error) {
  if (!config.spicedb_sync_enabled) {
    return true;
  }
  const std::string schema =
      "definition user {}\n"
      "definition subject {\n"
      "  relation revoked: user\n"
      "  permission denied = revoked\n"
      "}\n"
      "definition session {\n"
      "  relation revoked: user\n"
      "  permission denied = revoked\n"
      "}\n"
      "definition token {\n"
      "  relation revoked: user\n"
      "  permission denied = revoked\n"
      "}\n";
  const std::string body = reactive_mesh::json::object({{"schema", schema}});
  for (int attempt = 1; attempt <= 30; ++attempt) {
    reactive_mesh::http::ClientResponse response;
    if (reactive_mesh::http::request(config.spicedb_addr, "POST", "/v1/schema/write", body,
                                     {{"Content-Type", "application/json"},
                                      {"Authorization", "Bearer " + config.spicedb_preshared_key}},
                                     response) &&
        response.status >= 200 && response.status < 300) {
      return true;
    }
    error = "spicedb schema write failed";
    if (attempt != 30) {
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }
  }
  return false;
}

bool spiceDbWriteRevocations(const Config& config, const std::vector<std::pair<std::string, std::string>>& ids,
                             std::string& error) {
  if (!config.spicedb_sync_enabled) {
    return true;
  }
  std::string subject_type;
  std::string subject_id;
  if (!splitObjectRef(config.spicedb_policy_subject, subject_type, subject_id)) {
    error = "invalid SPICEDB_POLICY_SUBJECT";
    return false;
  }

  std::ostringstream updates;
  for (size_t i = 0; i < ids.size(); ++i) {
    const auto& [kind, value] = ids[i];
    if (i != 0) {
      updates << ',';
    }
    updates << "{\"operation\":\"OPERATION_TOUCH\",\"relationship\":{\"resource\":{\"objectType\":\""
            << reactive_mesh::json::escape(spiceDbObjectTypeFor(kind)) << "\",\"objectId\":\""
            << reactive_mesh::json::escape(value) << "\"},\"relation\":\"revoked\",\"subject\":{\"object\":{\"objectType\":\""
            << reactive_mesh::json::escape(subject_type) << "\",\"objectId\":\""
            << reactive_mesh::json::escape(subject_id) << "\"}}}}";
  }

  const std::string body = std::string("{\"updates\":[") + updates.str() + "]}";
  reactive_mesh::http::ClientResponse response;
  if (!reactive_mesh::http::request(config.spicedb_addr, "POST", "/v1/relationships/write", body,
                                    {{"Content-Type", "application/json"},
                                     {"Authorization", "Bearer " + config.spicedb_preshared_key}},
                                    response)) {
    error = "spicedb relationship write request failed";
    return false;
  }
  if (response.status < 200 || response.status >= 300) {
    error = "spicedb relationship write failed: " + std::to_string(response.status);
    return false;
  }
  return true;
}

} // namespace

int main() {
  const Config config{
      .listen_addr = getenvOr("LISTEN_ADDR", "0.0.0.0:8080"),
      .redis_addr = getenvOr("REDIS_ADDR", "redis:6379"),
      .redis_channel = getenvOr("REDIS_CHANNEL", "auth_events"),
      .state_ttl_seconds = getenvInt("STATE_TTL_SECONDS", 3600),
      .dedup_ttl_seconds = getenvInt("DEDUP_TTL_SECONDS", 86400),
      .jose_hs256_secret = getenvOr("JOSE_HS256_SECRET", ""),
      .require_signed = getenvBool("JOSE_REQUIRE_SIGNED", false),
      .openfga_sync_enabled = getenvBool("OPENFGA_SYNC_ENABLED", false),
      .openfga_addr = getenvOr("OPENFGA_ADDR", "openfga:8080"),
      .openfga_store_name = getenvOr("OPENFGA_STORE_NAME", "reactive-mesh-authz"),
      .openfga_policy_user = getenvOr("OPENFGA_POLICY_USER", "user:policy"),
      .spicedb_sync_enabled = getenvBool("SPICEDB_SYNC_ENABLED", false),
      .spicedb_addr = getenvOr("SPICEDB_ADDR", "spicedb:8443"),
      .spicedb_preshared_key = getenvOr("SPICEDB_PRESHARED_KEY", "reactive-mesh-token"),
      .spicedb_policy_subject = getenvOr("SPICEDB_POLICY_SUBJECT", "user:policy"),
  };
  Metrics metrics;
  const reactive_mesh::redis::Client redis(config.redis_addr);
  OpenFgaState openfga_state;

  std::cerr << "receiver-cpp: listen=" << config.listen_addr << " redis=" << config.redis_addr
            << " channel=" << config.redis_channel << " require_signed=" << (config.require_signed ? "true" : "false")
            << " openfga_sync_enabled=" << (config.openfga_sync_enabled ? "true" : "false")
            << " spicedb_sync_enabled=" << (config.spicedb_sync_enabled ? "true" : "false")
            << std::endl;

  if (config.openfga_sync_enabled) {
    std::string openfga_error;
    if (!initializeOpenFga(config, redis, openfga_state, openfga_error)) {
      std::cerr << "receiver-cpp: OpenFGA initialization failed: " << openfga_error << std::endl;
      return 1;
    }
    std::cerr << "receiver-cpp: OpenFGA initialized store_id=" << openfga_state.store_id
              << " model_id=" << openfga_state.model_id << std::endl;
  }
  if (config.spicedb_sync_enabled) {
    std::string spicedb_error;
    if (!initializeSpiceDb(config, spicedb_error)) {
      std::cerr << "receiver-cpp: SpiceDB initialization failed: " << spicedb_error << std::endl;
      return 1;
    }
    std::cerr << "receiver-cpp: SpiceDB initialized addr=" << config.spicedb_addr << std::endl;
  }

  reactive_mesh::http::serve(config.listen_addr, [&](const reactive_mesh::http::Request& request) {
    if (request.path == "/health") {
      return reactive_mesh::http::Response{.status = 200, .content_type = "application/json", .body = "{\"ok\":true}"};
    }

    if (request.path == "/metrics") {
      return reactive_mesh::http::Response{.status = 200, .content_type = "text/plain; version=0.0.4",
                                           .body = metricsBody(metrics)};
    }

    if (request.path == "/state") {
      metrics.receiver_state_queries_total.fetch_add(1);
      const std::string sub = request.query.contains("sub") ? request.query.at("sub") : "";
      const std::string sid = request.query.contains("sid") ? request.query.at("sid") : "";
      const std::string jti = request.query.contains("jti") ? request.query.at("jti") : "";
      const Event event{.sub = sub, .sid = sid, .jti = jti};
      const auto ids = collectIdentifiers(event);
      bool denied = false;
      std::vector<std::string> matched;
      for (const auto& [kind, value] : ids) {
        bool present = false;
        if (!redis.exists(denyKey(kind, value), present)) {
          return jsonError(502, "redis exists failed");
        }
        if (present) {
          denied = true;
          matched.push_back(kind + ":" + value);
        }
      }

      reactive_mesh::http::Response response;
      response.status = 200;
      response.body = std::string("{\"denied\":") + (denied ? "true" : "false") + ",\"matched\":" +
                      reactive_mesh::json::stringArray(matched) + "}";
      return response;
    }

    if (request.path == "/event") {
      if (request.method != "POST") {
        return jsonError(405, "method not allowed");
      }

      const auto parsed = parseEvent(request.body, config);
      if (!parsed.event.has_value()) {
        metrics.receiver_validation_failures_total.fetch_add(1);
        return jsonError(400, parsed.error.empty() ? "invalid event" : parsed.error);
      }
      Event event = *parsed.event;
      const auto ids = collectIdentifiers(event);
      if (ids.empty()) {
        metrics.receiver_validation_failures_total.fetch_add(1);
        return jsonError(400, "at least one of sub/sid/jti is required");
      }

      bool stored = false;
      if (!redis.setNxEx("event:" + event.event_id, config.dedup_ttl_seconds, "1", stored)) {
        return jsonError(502, "redis dedup failed");
      }
      if (!stored) {
        metrics.receiver_duplicate_events_total.fetch_add(1);
        reactive_mesh::http::Response response;
        response.status = 202;
        response.body = "{\"duplicate\":true,\"event_id\":\"" + reactive_mesh::json::escape(event.event_id) + "\"}";
        return response;
      }

      const std::string payload = reactive_mesh::json::object({
          {"event_id", event.event_id},
          {"event_type", event.event_type},
          {"sub", event.sub},
          {"sid", event.sid},
          {"jti", event.jti},
          {"reason", event.reason},
          {"ts", event.ts},
      });

      for (const auto& [kind, value] : ids) {
        if (!redis.setEx(denyKey(kind, value), config.state_ttl_seconds, payload)) {
          return jsonError(502, "redis state write failed");
        }
      }
      if (config.openfga_sync_enabled) {
        std::string openfga_error;
        if (!persistOpenFgaMetadata(redis, openfga_state, openfga_error)) {
          metrics.receiver_openfga_failures_total.fetch_add(1);
          return jsonError(502, openfga_error);
        }
        if (!openFgaWriteRevocations(config, openfga_state, ids, openfga_error)) {
          metrics.receiver_openfga_failures_total.fetch_add(1);
          return jsonError(502, openfga_error);
        }
        metrics.receiver_openfga_writes_total.fetch_add(1);
      }
      if (config.spicedb_sync_enabled) {
        std::string spicedb_error;
        if (!spiceDbWriteRevocations(config, ids, spicedb_error)) {
          metrics.receiver_spicedb_failures_total.fetch_add(1);
          return jsonError(502, spicedb_error);
        }
        metrics.receiver_spicedb_writes_total.fetch_add(1);
      }
      if (!redis.publish(config.redis_channel, payload)) {
        return jsonError(502, "redis publish failed");
      }

      metrics.receiver_events_total.fetch_add(1);
      std::vector<std::string> normalized_ids;
      normalized_ids.reserve(ids.size());
      for (const auto& [kind, value] : ids) {
        normalized_ids.push_back(kind + ":" + value);
      }

      reactive_mesh::http::Response response;
      response.status = 200;
      response.body = std::string("{\"published\":true,\"event_id\":\"") +
                      reactive_mesh::json::escape(event.event_id) + "\",\"event_type\":\"" +
                      reactive_mesh::json::escape(event.event_type) + "\",\"validation_source\":\"" +
                      reactive_mesh::json::escape(event.validation_source) + "\",\"identifiers\":" +
                      reactive_mesh::json::stringArray(normalized_ids) + "}";
      return response;
    }

    return jsonError(404, "not found");
  });
}
