#pragma once

#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace reactive_pep {

class RedisPubSubSubscriber {
public:
  using MessageCallback = std::function<void(const std::string& payload)>;

  RedisPubSubSubscriber(std::string host, uint16_t port, std::string channel, MessageCallback cb);
  ~RedisPubSubSubscriber();

  void start();
  void stop();

private:
  void run();

  // RESP parsing helpers (array of bulk strings only)
  static bool tryConsumeOneRespArray(std::string& buf, std::vector<std::string>& out_elems);
  static bool consumeLine(const std::string& buf, size_t& pos, std::string& out_line);

  std::string host_;
  uint16_t port_;
  std::string channel_;
  MessageCallback cb_;

  std::atomic<bool> stop_{false};
  std::thread thread_;
};

} // namespace reactive_pep
