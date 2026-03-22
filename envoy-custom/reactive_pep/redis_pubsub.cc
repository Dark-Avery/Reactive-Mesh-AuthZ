#include "reactive_pep/redis_pubsub.h"

#include <chrono>
#include <cstring>
#include <iostream>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <vector>

namespace reactive_pep {

namespace {

int connectTcp(const std::string& host, uint16_t port) {
  struct addrinfo hints;
  std::memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  struct addrinfo* res = nullptr;
  const std::string port_str = std::to_string(port);

  int rc = ::getaddrinfo(host.c_str(), port_str.c_str(), &hints, &res);
  if (rc != 0 || res == nullptr) {
    return -1;
  }

  int fd = -1;
  for (auto* p = res; p != nullptr; p = p->ai_next) {
    fd = ::socket(p->ai_family, p->ai_socktype, p->ai_protocol);
    if (fd < 0) {
      continue;
    }
    if (::connect(fd, p->ai_addr, p->ai_addrlen) == 0) {
      break;
    }
    ::close(fd);
    fd = -1;
  }

  ::freeaddrinfo(res);
  return fd;
}

bool sendAll(int fd, const std::string& s) {
  const char* data = s.data();
  size_t left = s.size();
  while (left > 0) {
    ssize_t n = ::send(fd, data, left, 0);
    if (n <= 0) {
      return false;
    }
    data += n;
    left -= static_cast<size_t>(n);
  }
  return true;
}

} // namespace

RedisPubSubSubscriber::RedisPubSubSubscriber(std::string host, uint16_t port, std::string channel,
                                             MessageCallback cb)
    : host_(std::move(host)), port_(port), channel_(std::move(channel)), cb_(std::move(cb)) {}

RedisPubSubSubscriber::~RedisPubSubSubscriber() { stop(); }

void RedisPubSubSubscriber::start() {
  if (thread_.joinable()) {
    return;
  }
  stop_.store(false);
  thread_ = std::thread([this]() { run(); });
}

void RedisPubSubSubscriber::stop() {
  stop_.store(true);
  if (thread_.joinable()) {
    thread_.join();
  }
}

void RedisPubSubSubscriber::run() {
  // Very small, dependency-free Redis Pub/Sub subscriber for demo purposes.
  // Uses RESP parsing for arrays of bulk strings.
  while (!stop_.load()) {
    int fd = connectTcp(host_, port_);
    if (fd < 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(500));
      continue;
    }

    // SUBSCRIBE <channel>
    const std::string cmd = "*2\r\n$9\r\nSUBSCRIBE\r\n$" + std::to_string(channel_.size()) +
                            "\r\n" + channel_ + "\r\n";
    if (!sendAll(fd, cmd)) {
      ::close(fd);
      std::this_thread::sleep_for(std::chrono::milliseconds(500));
      continue;
    }

    std::string buf;
    buf.reserve(16 * 1024);

    char tmp[4096];
    while (!stop_.load()) {
      ssize_t n = ::recv(fd, tmp, sizeof(tmp), 0);
      if (n <= 0) {
        break;
      }
      buf.append(tmp, static_cast<size_t>(n));

      // parse as many frames as possible
      while (true) {
        std::vector<std::string> elems;
        if (!tryConsumeOneRespArray(buf, elems)) {
          break;
        }
        if (elems.size() >= 3 && elems[0] == "message") {
          const std::string& payload = elems[2];
          if (cb_) {
            cb_(payload);
          }
        }
        // ignore subscribe/psubscribe acks
      }
    }

    ::close(fd);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  }
}

bool RedisPubSubSubscriber::consumeLine(const std::string& buf, size_t& pos, std::string& out_line) {
  const size_t eol = buf.find("\r\n", pos);
  if (eol == std::string::npos) {
    return false;
  }
  out_line.assign(buf.data() + pos, eol - pos);
  pos = eol + 2;
  return true;
}

bool RedisPubSubSubscriber::tryConsumeOneRespArray(std::string& buf, std::vector<std::string>& out_elems) {
  // Parse: *<n>\r\n $<len>\r\n<data>\r\n ...
  size_t pos = 0;
  if (buf.size() < 4) {
    return false;
  }
  if (buf[pos] != '*') {
    // if stream is desynced, drop buffer
    buf.clear();
    return false;
  }
  pos++;
  std::string line;
  if (!consumeLine(buf, pos, line)) {
    return false;
  }

  int n = 0;
  try {
    n = std::stoi(line);
  } catch (...) {
    buf.clear();
    return false;
  }
  if (n <= 0 || n > 16) {
    // sanity
    buf.clear();
    return false;
  }

  out_elems.clear();
  out_elems.reserve(static_cast<size_t>(n));

  for (int i = 0; i < n; i++) {
    if (pos >= buf.size()) {
      return false;
    }
    if (buf[pos] != '$') {
      // unsupported element type; drop frame
      buf.clear();
      return false;
    }
    pos++;
    if (!consumeLine(buf, pos, line)) {
      return false;
    }
    int len = 0;
    try {
      len = std::stoi(line);
    } catch (...) {
      buf.clear();
      return false;
    }
    if (len < 0) {
      // nil bulk string
      out_elems.emplace_back("");
      continue;
    }
    const size_t need = pos + static_cast<size_t>(len) + 2;
    if (buf.size() < need) {
      return false;
    }
    out_elems.emplace_back(buf.data() + pos, static_cast<size_t>(len));
    pos += static_cast<size_t>(len);
    if (buf.compare(pos, 2, "\r\n") != 0) {
      buf.clear();
      return false;
    }
    pos += 2;
  }

  // consume from buffer
  buf.erase(0, pos);
  return true;
}

} // namespace reactive_pep
