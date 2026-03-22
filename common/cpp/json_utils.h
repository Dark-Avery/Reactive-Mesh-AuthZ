#pragma once

#include <chrono>
#include <cctype>
#include <cstdint>
#include <iomanip>
#include <optional>
#include <random>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace reactive_mesh::json {

inline std::string trim(const std::string& value) {
  size_t start = 0;
  while (start < value.size() && std::isspace(static_cast<unsigned char>(value[start])) != 0) {
    start++;
  }
  size_t end = value.size();
  while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1])) != 0) {
    end--;
  }
  return value.substr(start, end - start);
}

inline std::optional<std::string> extractString(const std::string& body, const std::string& key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = body.find(needle);
  if (pos == std::string::npos) {
    return std::nullopt;
  }
  pos = body.find(':', pos + needle.size());
  if (pos == std::string::npos) {
    return std::nullopt;
  }
  pos++;
  while (pos < body.size() && std::isspace(static_cast<unsigned char>(body[pos])) != 0) {
    pos++;
  }
  if (pos >= body.size() || body[pos] != '"') {
    return std::nullopt;
  }
  pos++;
  std::string out;
  bool escaped = false;
  for (; pos < body.size(); ++pos) {
    const char ch = body[pos];
    if (escaped) {
      switch (ch) {
      case '"':
      case '\\':
      case '/':
        out.push_back(ch);
        break;
      case 'b':
        out.push_back('\b');
        break;
      case 'f':
        out.push_back('\f');
        break;
      case 'n':
        out.push_back('\n');
        break;
      case 'r':
        out.push_back('\r');
        break;
      case 't':
        out.push_back('\t');
        break;
      default:
        out.push_back(ch);
        break;
      }
      escaped = false;
      continue;
    }
    if (ch == '\\') {
      escaped = true;
      continue;
    }
    if (ch == '"') {
      return trim(out);
    }
    out.push_back(ch);
  }
  return std::nullopt;
}

inline std::string escape(const std::string& value) {
  std::ostringstream out;
  for (const char ch : value) {
    switch (ch) {
    case '\\':
      out << "\\\\";
      break;
    case '"':
      out << "\\\"";
      break;
    case '\b':
      out << "\\b";
      break;
    case '\f':
      out << "\\f";
      break;
    case '\n':
      out << "\\n";
      break;
    case '\r':
      out << "\\r";
      break;
    case '\t':
      out << "\\t";
      break;
    default:
      if (static_cast<unsigned char>(ch) < 0x20U) {
        out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
            << static_cast<int>(static_cast<unsigned char>(ch)) << std::dec;
      } else {
        out << ch;
      }
      break;
    }
  }
  return out.str();
}

inline std::string randomHexId() {
  std::random_device rd;
  std::uniform_int_distribution<int> dist(0, 255);
  std::ostringstream out;
  out << std::hex << std::setfill('0');
  for (int i = 0; i < 16; ++i) {
    out << std::setw(2) << dist(rd);
  }
  return out.str();
}

inline std::string nowRfc3339Nano() {
  const auto now = std::chrono::system_clock::now();
  const auto secs = std::chrono::time_point_cast<std::chrono::seconds>(now);
  const auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(now - secs).count();
  const std::time_t tt = std::chrono::system_clock::to_time_t(now);

  std::tm tm{};
#if defined(_WIN32)
  gmtime_s(&tm, &tt);
#else
  gmtime_r(&tt, &tm);
#endif

  std::ostringstream out;
  out << std::put_time(&tm, "%Y-%m-%dT%H:%M:%S") << '.' << std::setw(9) << std::setfill('0') << nanos << 'Z';
  return out.str();
}

inline std::string object(const std::vector<std::pair<std::string, std::string>>& fields) {
  std::ostringstream out;
  out << '{';
  bool first = true;
  for (const auto& [key, value] : fields) {
    if (!first) {
      out << ',';
    }
    first = false;
    out << '"' << escape(key) << "\":\"" << escape(value) << '"';
  }
  out << '}';
  return out.str();
}

inline std::string stringArray(const std::vector<std::string>& values) {
  std::ostringstream out;
  out << '[';
  for (size_t i = 0; i < values.size(); ++i) {
    if (i != 0) {
      out << ',';
    }
    out << '"' << escape(values[i]) << '"';
  }
  out << ']';
  return out.str();
}

} // namespace reactive_mesh::json
