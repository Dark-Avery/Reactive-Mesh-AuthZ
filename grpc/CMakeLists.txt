cmake_minimum_required(VERSION 3.16)
project(reactive_mesh_grpc_cpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Protobuf REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GRPC REQUIRED grpc++)
find_program(GRPC_CPP_PLUGIN_EXECUTABLE grpc_cpp_plugin REQUIRED)

set(PROTO_DIR ${CMAKE_CURRENT_SOURCE_DIR}/proto)
set(GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GEN_DIR})

set(PROTO_FILE ${PROTO_DIR}/stream.proto)
set(PROTO_SRCS ${GEN_DIR}/stream.pb.cc ${GEN_DIR}/stream.grpc.pb.cc)
set(PROTO_HDRS ${GEN_DIR}/stream.pb.h ${GEN_DIR}/stream.grpc.pb.h)

add_custom_command(
  OUTPUT ${PROTO_SRCS} ${PROTO_HDRS}
  COMMAND ${Protobuf_PROTOC_EXECUTABLE}
  ARGS
    --proto_path=${PROTO_DIR}
    --proto_path=/usr/include
    --cpp_out=${GEN_DIR}
    --grpc_out=${GEN_DIR}
    --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN_EXECUTABLE}
    ${PROTO_FILE}
  DEPENDS ${PROTO_FILE}
)

add_library(reactive_mesh_proto ${PROTO_SRCS})
target_include_directories(reactive_mesh_proto PUBLIC ${GEN_DIR} ${Protobuf_INCLUDE_DIRS} ${GRPC_INCLUDE_DIRS})
target_link_libraries(reactive_mesh_proto PUBLIC ${Protobuf_LIBRARIES} ${GRPC_LINK_LIBRARIES})
target_compile_options(reactive_mesh_proto PUBLIC ${GRPC_CFLAGS_OTHER})

add_executable(grpc-server cpp/server.cpp)
target_include_directories(grpc-server PRIVATE ${GEN_DIR})
target_link_libraries(grpc-server PRIVATE reactive_mesh_proto ${Protobuf_LIBRARIES} ${GRPC_LINK_LIBRARIES})
target_compile_options(grpc-server PRIVATE ${GRPC_CFLAGS_OTHER})

add_executable(grpc-client cpp/client.cpp)
target_include_directories(grpc-client PRIVATE ${GEN_DIR})
target_link_libraries(grpc-client PRIVATE reactive_mesh_proto ${Protobuf_LIBRARIES} ${GRPC_LINK_LIBRARIES})
target_compile_options(grpc-client PRIVATE ${GRPC_CFLAGS_OTHER})
