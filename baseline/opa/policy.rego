package envoy.authz

import rego.v1

default allow := false

allow if {
  state := state_response
  state.status_code == 200
  not state.body.denied
}

state_response := http.send({
  "method": "get",
  "url": sprintf(
    "http://receiver:8080/state?sub=%s&sid=%s&jti=%s",
    [
      object.get(object.get(input.attributes.request.http, "headers", {}), "x-sub", ""),
      object.get(object.get(input.attributes.request.http, "headers", {}), "x-sid", ""),
      object.get(object.get(input.attributes.request.http, "headers", {}), "x-jti", ""),
    ],
  ),
  "force_json_decode": true,
})
