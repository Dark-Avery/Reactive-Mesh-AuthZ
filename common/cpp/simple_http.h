#pragma once

#include <algorithm>
#include <arpa/inet.h>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <functional>
#include <map>
#include <netdb.h>
#include <netinet/in.h>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/types.h>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

namespace reactive_mesh::http {

inline std::string toLower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
  return value;
}

inline std::string trim(const std::string& value) {
  size_t start = 0;
  while (start < value.size() && std::isspace(static_cast<unsigned char>(value[start])) != 0) {
    ++start;
  }
  size_t end = value.size();
  while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1])) != 0) {
    --end;
  }
  return value.substr(start, end - start);
}

inline std::string urlDecode(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (size_t i = 0; i < value.size(); ++i) {
    if (value[i] == '+' ) {
      out.push_back(' ');
      continue;
    }
    if (value[i] == '%' && i + 2 < value.size()) {
      const auto hex = value.substr(i + 1, 2);
      out.push_back(static_cast<char>(std::strtol(hex.c_str(), nullptr, 16)));
      i += 2;
      continue;
    }
    out.push_back(value[i]);
  }
  return out;
}

struct Request {
  std::string method;
  std::string target;
  std::string path;
  std::map<std::string, std::string> headers;
  std::map<std::string, std::string> query;
  std::string body;
};

struct Response {
  int status{200};
  std::string content_type{"application/json"};
  std::string body{"{}"};
  std::vector<std::pair<std::string, std::string>> headers;
};

struct ClientResponse {
  int status{0};
  std::map<std::string, std::string> headers;
  std::string body;
};

inline const char* statusText(const int status) {
  switch (status) {
  case 200:
    return "OK";
  case 202:
    return "Accepted";
  case 400:
    return "Bad Request";
  case 403:
    return "Forbidden";
  case 404:
    return "Not Found";
  case 405:
    return "Method Not Allowed";
  case 502:
    return "Bad Gateway";
  default:
    return "Internal Server Error";
  }
}

inline bool sendAll(int fd, const std::string& payload) {
  size_t written = 0;
  while (written < payload.size()) {
    const ssize_t n = ::send(fd, payload.data() + written, payload.size() - written, 0);
    if (n <= 0) {
      return false;
    }
    written += static_cast<size_t>(n);
  }
  return true;
}

inline bool readRequest(int fd, Request& request) {
  std::string buffer;
  buffer.reserve(8192);
  char chunk[4096];
  size_t header_end = std::string::npos;
  while (buffer.size() < 1024 * 1024) {
    header_end = buffer.find("\r\n\r\n");
    if (header_end != std::string::npos) {
      break;
    }
    const ssize_t n = ::recv(fd, chunk, sizeof(chunk), 0);
    if (n <= 0) {
      return false;
    }
    buffer.append(chunk, static_cast<size_t>(n));
  }
  if (header_end == std::string::npos) {
    return false;
  }

  const std::string head = buffer.substr(0, header_end);
  size_t body_start = header_end + 4;
  std::istringstream input(head);
  std::string line;
  if (!std::getline(input, line)) {
    return false;
  }
  if (!line.empty() && line.back() == '\r') {
    line.pop_back();
  }
  std::istringstream start(line);
  if (!(start >> request.method >> request.target)) {
    return false;
  }

  const size_t qmark = request.target.find('?');
  request.path = qmark == std::string::npos ? request.target : request.target.substr(0, qmark);
  request.query.clear();
  if (qmark != std::string::npos) {
    std::string query = request.target.substr(qmark + 1);
    size_t pos = 0;
    while (pos <= query.size()) {
      size_t amp = query.find('&', pos);
      std::string part = query.substr(pos, amp == std::string::npos ? std::string::npos : amp - pos);
      if (!part.empty()) {
        const size_t eq = part.find('=');
        const std::string key = urlDecode(part.substr(0, eq));
        const std::string val = eq == std::string::npos ? "" : urlDecode(part.substr(eq + 1));
        request.query[key] = val;
      }
      if (amp == std::string::npos) {
        break;
      }
      pos = amp + 1;
    }
  }

  request.headers.clear();
  while (std::getline(input, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    const size_t colon = line.find(':');
    if (colon == std::string::npos) {
      continue;
    }
    request.headers[toLower(trim(line.substr(0, colon)))] = trim(line.substr(colon + 1));
  }

  size_t content_length = 0;
  auto it = request.headers.find("content-length");
  if (it != request.headers.end()) {
    content_length = static_cast<size_t>(std::stoul(it->second));
  }

  request.body = buffer.substr(body_start);
  while (request.body.size() < content_length) {
    const ssize_t n = ::recv(fd, chunk, std::min(sizeof(chunk), content_length - request.body.size()), 0);
    if (n <= 0) {
      return false;
    }
    request.body.append(chunk, static_cast<size_t>(n));
  }
  return true;
}

inline void writeResponse(int fd, const Response& response) {
  std::ostringstream out;
  out << "HTTP/1.1 " << response.status << ' ' << statusText(response.status) << "\r\n";
  out << "Content-Type: " << response.content_type << "\r\n";
  out << "Content-Length: " << response.body.size() << "\r\n";
  out << "Connection: close\r\n";
  for (const auto& [key, value] : response.headers) {
    out << key << ": " << value << "\r\n";
  }
  out << "\r\n";
  out << response.body;
  const std::string payload = out.str();
  sendAll(fd, payload);
}

inline bool parseListenAddress(const std::string& listen_addr, std::string& host, uint16_t& port) {
  const size_t colon = listen_addr.rfind(':');
  if (colon == std::string::npos) {
    return false;
  }
  host = listen_addr.substr(0, colon);
  if (host.empty()) {
    host = "0.0.0.0";
  }
  port = static_cast<uint16_t>(std::stoul(listen_addr.substr(colon + 1)));
  return true;
}

inline int connectTcp(const std::string& address) {
  std::string host;
  uint16_t port = 0;
  if (!parseListenAddress(address, host, port)) {
    return -1;
  }

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

inline bool readResponse(int fd, ClientResponse& response) {
  std::string buffer;
  buffer.reserve(8192);
  char chunk[4096];
  size_t header_end = std::string::npos;
  while (buffer.size() < 1024 * 1024) {
    header_end = buffer.find("\r\n\r\n");
    if (header_end != std::string::npos) {
      break;
    }
    const ssize_t n = ::recv(fd, chunk, sizeof(chunk), 0);
    if (n <= 0) {
      return false;
    }
    buffer.append(chunk, static_cast<size_t>(n));
  }
  if (header_end == std::string::npos) {
    return false;
  }

  const std::string head = buffer.substr(0, header_end);
  size_t body_start = header_end + 4;
  std::istringstream input(head);
  std::string line;
  if (!std::getline(input, line)) {
    return false;
  }
  if (!line.empty() && line.back() == '\r') {
    line.pop_back();
  }
  std::istringstream status_line(line);
  std::string http_version;
  if (!(status_line >> http_version >> response.status)) {
    return false;
  }

  response.headers.clear();
  while (std::getline(input, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    const size_t colon = line.find(':');
    if (colon == std::string::npos) {
      continue;
    }
    response.headers[toLower(trim(line.substr(0, colon)))] = trim(line.substr(colon + 1));
  }

  size_t content_length = 0;
  auto it = response.headers.find("content-length");
  if (it != response.headers.end()) {
    content_length = static_cast<size_t>(std::stoul(it->second));
  }

  response.body = buffer.substr(body_start);
  while (response.body.size() < content_length) {
    const ssize_t n = ::recv(fd, chunk, std::min(sizeof(chunk), content_length - response.body.size()), 0);
    if (n <= 0) {
      return false;
    }
    response.body.append(chunk, static_cast<size_t>(n));
  }
  return true;
}

inline bool request(const std::string& address, const std::string& method, const std::string& path,
                    const std::string& body, const std::vector<std::pair<std::string, std::string>>& headers,
                    ClientResponse& response) {
  const int fd = connectTcp(address);
  if (fd < 0) {
    return false;
  }

  std::ostringstream out;
  out << method << ' ' << path << " HTTP/1.1\r\n";
  out << "Host: " << address << "\r\n";
  out << "Connection: close\r\n";
  out << "Content-Length: " << body.size() << "\r\n";
  for (const auto& [key, value] : headers) {
    out << key << ": " << value << "\r\n";
  }
  out << "\r\n";
  out << body;

  const std::string payload = out.str();
  const bool sent = sendAll(fd, payload);
  const bool read = sent && readResponse(fd, response);
  ::close(fd);
  return read;
}

inline int bindAndListen(const std::string& listen_addr) {
  std::string host;
  uint16_t port = 0;
  if (!parseListenAddress(listen_addr, host, port)) {
    return -1;
  }

  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }

  int one = 1;
  ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

  sockaddr_in addr {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  if (host == "0.0.0.0") {
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
  } else {
    addr.sin_addr.s_addr = ::inet_addr(host.c_str());
  }

  if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    ::close(fd);
    return -1;
  }
  if (::listen(fd, 128) != 0) {
    ::close(fd);
    return -1;
  }
  return fd;
}

inline void serve(const std::string& listen_addr, const std::function<Response(const Request&)>& handler) {
  const int server_fd = bindAndListen(listen_addr);
  if (server_fd < 0) {
    throw std::runtime_error("failed to bind " + listen_addr);
  }

  while (true) {
    sockaddr_storage peer {};
    socklen_t peer_len = sizeof(peer);
    const int client_fd = ::accept(server_fd, reinterpret_cast<sockaddr*>(&peer), &peer_len);
    if (client_fd < 0) {
      continue;
    }
    std::thread([client_fd, handler]() {
      Request request;
      Response response;
      if (!readRequest(client_fd, request)) {
        response.status = 400;
        response.body = "{\"error\":\"bad request\"}";
      } else {
        response = handler(request);
      }
      writeResponse(client_fd, response);
      ::close(client_fd);
    }).detach();
  }
}

} // namespace reactive_mesh::http
