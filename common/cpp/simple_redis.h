#pragma once

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <netdb.h>
#include <optional>
#include <string>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace reactive_mesh::redis {

inline bool splitAddress(const std::string& addr, std::string& host, uint16_t& port) {
  const size_t colon = addr.rfind(':');
  if (colon == std::string::npos) {
    return false;
  }
  host = addr.substr(0, colon);
  try {
    const auto parsed = std::stoul(addr.substr(colon + 1));
    if (parsed > 65535) {
      return false;
    }
    port = static_cast<uint16_t>(parsed);
  } catch (...) {
    return false;
  }
  return !host.empty();
}

inline int connectTcp(const std::string& host, uint16_t port) {
  struct addrinfo hints {};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  struct addrinfo* result = nullptr;
  const std::string port_string = std::to_string(port);
  const int rc = ::getaddrinfo(host.c_str(), port_string.c_str(), &hints, &result);
  if (rc != 0 || result == nullptr) {
    return -1;
  }

  int fd = -1;
  for (struct addrinfo* it = result; it != nullptr; it = it->ai_next) {
    fd = ::socket(it->ai_family, it->ai_socktype, it->ai_protocol);
    if (fd < 0) {
      continue;
    }
    if (::connect(fd, it->ai_addr, it->ai_addrlen) == 0) {
      break;
    }
    ::close(fd);
    fd = -1;
  }

  ::freeaddrinfo(result);
  return fd;
}

inline bool sendAll(int fd, const std::string& data) {
  size_t sent = 0;
  while (sent < data.size()) {
    const ssize_t n = ::send(fd, data.data() + sent, data.size() - sent, 0);
    if (n <= 0) {
      return false;
    }
    sent += static_cast<size_t>(n);
  }
  return true;
}

inline bool readExact(int fd, size_t size, std::string& out) {
  out.clear();
  out.reserve(size);
  while (out.size() < size) {
    char buf[1024];
    const size_t want = std::min(sizeof(buf), size - out.size());
    const ssize_t n = ::recv(fd, buf, want, 0);
    if (n <= 0) {
      return false;
    }
    out.append(buf, static_cast<size_t>(n));
  }
  return true;
}

inline bool readLine(int fd, std::string& out) {
  out.clear();
  char ch = '\0';
  while (true) {
    const ssize_t n = ::recv(fd, &ch, 1, 0);
    if (n <= 0) {
      return false;
    }
    out.push_back(ch);
    if (out.size() >= 2 && out[out.size() - 2] == '\r' && out[out.size() - 1] == '\n') {
      out.resize(out.size() - 2);
      return true;
    }
  }
}

struct Reply {
  enum class Type {
    kSimpleString,
    kError,
    kInteger,
    kBulkString,
    kNil,
  };

  Type type{Type::kError};
  std::string string_value;
  int64_t int_value{0};
};

inline bool readReply(int fd, Reply& out) {
  char marker = '\0';
  if (::recv(fd, &marker, 1, 0) != 1) {
    return false;
  }

  std::string line;
  switch (marker) {
  case '+':
    if (!readLine(fd, line)) {
      return false;
    }
    out.type = Reply::Type::kSimpleString;
    out.string_value = line;
    return true;
  case '-':
    if (!readLine(fd, line)) {
      return false;
    }
    out.type = Reply::Type::kError;
    out.string_value = line;
    return true;
  case ':':
    if (!readLine(fd, line)) {
      return false;
    }
    out.type = Reply::Type::kInteger;
    out.int_value = std::stoll(line);
    return true;
  case '$': {
    if (!readLine(fd, line)) {
      return false;
    }
    const int64_t len = std::stoll(line);
    if (len < 0) {
      out.type = Reply::Type::kNil;
      out.string_value.clear();
      return true;
    }
    std::string payload;
    if (!readExact(fd, static_cast<size_t>(len) + 2, payload)) {
      return false;
    }
    out.type = Reply::Type::kBulkString;
    out.string_value = payload.substr(0, static_cast<size_t>(len));
    return true;
  }
  default:
    return false;
  }
}

inline std::string encodeCommand(const std::vector<std::string>& args) {
  std::string out = "*" + std::to_string(args.size()) + "\r\n";
  for (const auto& arg : args) {
    out += "$" + std::to_string(arg.size()) + "\r\n" + arg + "\r\n";
  }
  return out;
}

class Client {
public:
  explicit Client(std::string address) : address_(std::move(address)) {}

  bool setEx(const std::string& key, int ttl_seconds, const std::string& value) const {
    Reply reply;
    if (!exec({"SET", key, value, "EX", std::to_string(ttl_seconds)}, reply)) {
      return false;
    }
    return reply.type == Reply::Type::kSimpleString && reply.string_value == "OK";
  }

  bool set(const std::string& key, const std::string& value) const {
    Reply reply;
    if (!exec({"SET", key, value}, reply)) {
      return false;
    }
    return reply.type == Reply::Type::kSimpleString && reply.string_value == "OK";
  }

  bool setNxEx(const std::string& key, int ttl_seconds, const std::string& value, bool& stored) const {
    Reply reply;
    if (!exec({"SET", key, value, "EX", std::to_string(ttl_seconds), "NX"}, reply)) {
      return false;
    }
    stored = reply.type == Reply::Type::kSimpleString && reply.string_value == "OK";
    return stored || reply.type == Reply::Type::kNil;
  }

  bool exists(const std::string& key, bool& present) const {
    Reply reply;
    if (!exec({"EXISTS", key}, reply)) {
      return false;
    }
    present = reply.type == Reply::Type::kInteger && reply.int_value > 0;
    return reply.type == Reply::Type::kInteger;
  }

  bool get(const std::string& key, std::optional<std::string>& value) const {
    Reply reply;
    if (!exec({"GET", key}, reply)) {
      return false;
    }
    if (reply.type == Reply::Type::kNil) {
      value = std::nullopt;
      return true;
    }
    if (reply.type != Reply::Type::kBulkString) {
      return false;
    }
    value = reply.string_value;
    return true;
  }

  bool publish(const std::string& channel, const std::string& payload) const {
    Reply reply;
    if (!exec({"PUBLISH", channel, payload}, reply)) {
      return false;
    }
    return reply.type == Reply::Type::kInteger;
  }

private:
  bool exec(const std::vector<std::string>& args, Reply& reply) const {
    std::string host;
    uint16_t port = 0;
    if (!splitAddress(address_, host, port)) {
      return false;
    }

    const int fd = connectTcp(host, port);
    if (fd < 0) {
      return false;
    }

    const std::string command = encodeCommand(args);
    const bool sent = sendAll(fd, command);
    const bool read = sent && readReply(fd, reply);
    ::close(fd);
    return read;
  }

  std::string address_;
};

} // namespace reactive_mesh::redis
