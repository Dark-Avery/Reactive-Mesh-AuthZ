# Сценарий для kind

```bash
sudo kind create cluster --config deploy/kind/kind-config.yaml
sudo docker build -f receiver/Dockerfile -t reactive-mesh/receiver:dev .
sudo docker build -f grpc/server/Dockerfile -t reactive-mesh/grpc-server:dev .
sudo docker build -f grpc/client/Dockerfile -t reactive-mesh/grpc-client:dev .
sudo docker pull openpolicyagent/opa:latest-envoy-static
sudo docker tag openpolicyagent/opa:latest-envoy-static reactive-mesh/opa-envoy:dev
sudo docker build -f envoy/Dockerfile --build-arg ENVOY_CONFIG=envoy-reactive.yaml -t reactive-mesh/envoy-reactive:dev .
sudo docker build -f envoy/Dockerfile --build-arg ENVOY_CONFIG=envoy-baseline.yaml -t reactive-mesh/envoy-baseline:dev .
sudo kind load docker-image reactive-mesh/receiver:dev reactive-mesh/grpc-server:dev reactive-mesh/opa-envoy:dev reactive-mesh/envoy-reactive:dev reactive-mesh/envoy-baseline:dev --name reactive-mesh-authz
kubectl apply -k deploy/kustomize/overlays/reactive
```

Для архитектуры сравнения `OPA + Envoy`:

```bash
kubectl apply -k deploy/kustomize/overlays/baseline
```
