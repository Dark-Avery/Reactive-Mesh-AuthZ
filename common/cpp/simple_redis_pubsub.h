#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "common/cpp/simple_redis.h"

namespace reactive_mesh::redis {

class PubSubSubscriber {
public:
  using MessageCallback = std::function<void(const std::string& payload)>;

  PubSubSubscriber(std::string address, std::string channel, MessageCallback cb)
      : address_(std::move(address)), channel_(std::move(channel)), cb_(std::move(cb)) {}

  ~PubSubSubscriber() { stop(); }

  void start() {
    if (thread_.joinable()) {
      return;
    }
    stop_.store(false);
    thread_ = std::thread([this]() { run(); });
  }

  void stop() {
    stop_.store(true);
    if (thread_.joinable()) {
      thread_.join();
    }
  }

private:
  static bool consumeLine(const std::string& buf, size_t& pos, std::string& out_line) {
    const size_t eol = buf.find("\r\n", pos);
    if (eol == std::string::npos) {
      return false;
    }
    out_line.assign(buf.data() + pos, eol - pos);
    pos = eol + 2;
    return true;
  }

  static bool tryConsumeOneRespArray(std::string& buf, std::vector<std::string>& out_elems) {
    size_t pos = 0;
    if (buf.size() < 4) {
      return false;
    }
    if (buf[pos] != '*') {
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
      buf.clear();
      return false;
    }

    out_elems.clear();
    out_elems.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
      if (pos >= buf.size()) {
        return false;
      }
      if (buf[pos] != '$') {
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

    buf.erase(0, pos);
    return true;
  }

  void run() {
    std::string host;
    uint16_t port = 0;
    if (!splitAddress(address_, host, port)) {
      return;
    }

    while (!stop_.load()) {
      const int fd = connectTcp(host, port);
      if (fd < 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        continue;
      }

      const std::string cmd = "*2\r\n$9\r\nSUBSCRIBE\r\n$" + std::to_string(channel_.size()) + "\r\n" + channel_ + "\r\n";
      if (!sendAll(fd, cmd)) {
        ::close(fd);
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        continue;
      }

      std::string buf;
      buf.reserve(16 * 1024);

      char tmp[4096];
      while (!stop_.load()) {
        const ssize_t n = ::recv(fd, tmp, sizeof(tmp), 0);
        if (n <= 0) {
          break;
        }
        buf.append(tmp, static_cast<size_t>(n));
        while (true) {
          std::vector<std::string> elems;
          if (!tryConsumeOneRespArray(buf, elems)) {
            break;
          }
          if (elems.size() >= 3 && elems[0] == "message" && cb_) {
            cb_(elems[2]);
          }
        }
      }

      ::close(fd);
      std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
  }

  std::string address_;
  std::string channel_;
  MessageCallback cb_;
  std::atomic<bool> stop_{false};
  std::thread thread_;
};

} // namespace reactive_mesh::redis
