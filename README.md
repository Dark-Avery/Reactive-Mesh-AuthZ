# Reactive Mesh AuthZ

Открытый исследовательский проект для реактивного применения авторизации в сервисной сетке на базе Envoy по событиям класса SSF/CAEP/SET.

Проект реализует полный контур:

- локальный IdP через OIDC/JWKS;
- приём событий отзыва и риска;
- хранение состояния запрета и отзыва в Redis;
- реактивный PEP в Envoy для активных gRPC-потоков;
- режимы сравнения на базе `OPA + Envoy`, `Istio CUSTOM` и `OpenFGA`;
- воспроизводимые эксперименты, графики и формальную модель на TLA+.

## Состав проекта

- [receiver/cpp](receiver/cpp) — C++ приёмник событий с валидацией, нормализацией, дедупликацией и TTL-состоянием.
- [envoy-custom/reactive_pep](envoy-custom/reactive_pep) — C++ фильтр Envoy для реактивного завершения потока по `sub/sid/jti`.
- [baseline/opa](baseline/opa) — сервисы и политики для архитектур сравнения.
- [grpc/cpp](grpc/cpp) — демонстрационный gRPC-сервер и клиент.
- [bench/load-client](bench/load-client) — сценарии нагрузочного прогона и измерений.
- [deploy/kustomize](deploy/kustomize), [deploy/helm](deploy/helm), [deploy/kind](deploy/kind) — упаковка и локальное развёртывание.
- [formal/tla](formal/tla) — формальная модель и проверка свойств.
- [docs/README.md](docs/README.md) — навигация по документации проекта.

## Лицензия

Проект распространяется по лицензии [Apache 2.0](LICENSE).

## Быстрый старт

Для локальной проверки стенда:

```bash
make install-metrics-server
make verify-mvp
cat experiments/results/verify-mvp/summary.json
cat experiments/results/verify-mvp/correctness-report.json
```

Этот сценарий поднимает локальный стенд, запускает реактивную проверку, режимы сравнения, формальную проверку и собирает метрики корректности. Локальные файлы проверки считаются временными и в GitHub-версию репозитория не входят.

## Что собирает CI

Публичный CI в этом репозитории должен собирать только компоненты, необходимые для воспроизводимого стенда и короткой контрольной проверки основных открытых архитектур сравнения:

- `reactive-mesh/receiver:dev`
- `reactive-mesh/baseline-authz:dev`
- `reactive-mesh/grpc-server:dev`
- `reactive-mesh/redis:dev`
- `reactive-mesh/demo-idp:v2`
- `reactive-mesh/openfga:v1.12.1-dev`
- `reactive-mesh/opa-envoy:dev`
- `reactive-mesh/envoy-reactive:dev`
- `reactive-mesh/envoy-baseline:dev`

После сборки CI должен:

- поднять `kind`-кластер;
- развернуть локальный IdP и реактивный стенд;
- прогнать единую короткую проверку стенда;
- отдельно подтвердить `OPA + Envoy`, `Istio CUSTOM` и `OpenFGA`.

Для проверки `Istio CUSTOM` CI не собирает собственный образ Istio, а подтягивает официальные образы Istio во время прогона.

CI не должен собирать полный исследовательский набор повторов, дополнительные локальные режимы внутренней проверки, дипломные PDF и временные каталоги проверки.

## Центральные результаты

В репозитории сохранены только центральные артефакты, на которые опирается итоговая работа:

- основной сводный набор результатов:
  [experiments/results/matrix-summary-full.json](experiments/results/matrix-summary-full.json)
- агрегированный статистический отчёт:
  [experiments/results/matrix-report-full.json](experiments/results/matrix-report-full.json)
- итоговый компактный пакет результатов:
  [experiments/results/final-experiment-summary.json](experiments/results/final-experiment-summary.json)
- основные графики:
  [experiments/results/plots/oss_risk_window_by_profile.png](experiments/results/plots/oss_risk_window_by_profile.png),
  [experiments/results/plots/oss_gap_vs_reactive.png](experiments/results/plots/oss_gap_vs_reactive.png),
  [experiments/results/plots/reactive_latency_by_profile.png](experiments/results/plots/reactive_latency_by_profile.png)

Ключевой вывод по этим артефактам: реактивный режим завершает уже активный gRPC-поток после события отзыва и сокращает окно риска относительно архитектур сравнения, которые принимают решение только в момент нового запроса.

## Архитектуры сравнения

Основное публичное сравнение проекта строится вокруг трёх архитектур с открытым исходным кодом:

- `OPA + Envoy` — внешняя авторизация в момент запроса на уровне прокси;
- `Istio CUSTOM` — внешняя авторизация в сервисной сетке;
- `OpenFGA` — централизованная детализированная авторизация.

Дополнительные локальные режимы проверки сохранены отдельно и не входят в центральный публичный набор результатов.

Если нужно отдельно проверить локальную IdP-интеграцию через OIDC/JWKS токен доступа:

```bash
DOCKER_BUILDKIT=0 ./scripts/verify_demo_idp_reactive.sh
DOCKER_BUILDKIT=0 ./scripts/verify_demo_idp_baseline.sh
cat experiments/results/verify-demo-idp-reactive/summary.json
cat experiments/results/verify-demo-idp-baseline/summary.json
```

Этот путь подтверждает:

- `demo-idp -> Envoy jwt_authn -> x-sub/x-sid/x-jti -> реактивный PEP`
- `demo-idp -> Envoy jwt_authn -> OPA + Envoy`
- прерывание уже активного потока в реактивном режиме
- отсутствие прерывания уже активного потока, но корректный запрет повторного открытия в архитектуре `OPA + Envoy`

Если нужно отдельно проверить сравнение с реальными open-source архитектурами, используйте:

```bash
./scripts/verify_oss_comparators.sh
cat experiments/results/verify-oss-comparators/summary.json
```

Этот сценарий подтверждает дополнительные рабочие пути сравнения:

- `OPA + Envoy` как внешнюю авторизацию в момент запроса
- `Istio CUSTOM` как внешнюю авторизацию в сервисной сетке
- `OpenFGA` как централизованную детализированную авторизацию

Если нужно пересобрать основной агрегированный статистический отчёт по матрице сравнения:

```bash
make matrix-report
python3 experiments/prepare_final_results.py
```

Главные артефакты:

- [experiments/results/matrix-report-full.json](experiments/results/matrix-report-full.json)
- [experiments/results/final-experiment-summary.json](experiments/results/final-experiment-summary.json)

## Структура репозитория

```text
/receiver/cpp
/pep/envoy-wasm
/pep/envoy-native
/baseline/opa
/upstream/grpc-server        # в текущем стенде соответствует grpc/cpp/server.cpp
/bench/load-client
/deploy/kind
/deploy/helm
/deploy/kustomize
/experiments
/formal/tla
/docs/architecture
/docs/related-work
/docs/evaluation
```

## Что нужно установить локально

Перед локальной сборкой и запуском стенда должны быть доступны:

- `cmake`
- `g++`
- `protoc`
- `grpc_cpp_plugin`
- `libgrpc++`
- `kubectl`
- `kind`
- `helm`

## Локальная сборка бинарников

```bash
make build-receiver
make build-baseline
make build-grpc-cpp
```

Артефакты:

- `/tmp/reactive-mesh-receiver`
- `/tmp/reactive-mesh-baseline`
- `/tmp/reactive-mesh-grpc-build/grpc-server`
- `/tmp/reactive-mesh-grpc-build/grpc-client`

## Режимы Docker Compose

Режим `reactive`:

```bash
docker compose --profile reactive up --build
```

Режим `baseline`:

```bash
docker compose --profile baseline up --build
```

Этот compose-путь использует реальный режим сравнения `OPA + Envoy`.
Основное публичное сравнение проекта строится вокруг трёх архитектур с открытым исходным кодом:

- внешняя авторизация в момент запроса: `OPA + Envoy`
- внешняя авторизация в сервисной сетке: `Istio CUSTOM`
- централизованная детализированная авторизация: `OpenFGA`

Дополнительные внутренние абляции и вспомогательные контуры сравнения сохранены только для локальной инженерной проверки и не входят в основной публичный набор результатов.

Состав compose-стека:

- `redis`
- `receiver`
- `grpc-server`
- `opa`
- `envoy-reactive` или `envoy-baseline`
- `grpc-client` как запускаемый по требованию клиент

Пример запуска клиента в режиме `reactive`:

```bash
docker compose run --rm -e GRPC_ADDR=envoy-reactive:8081 grpc-client --sub alice --sid s1 --jti t1
```

Отправка revoke:

```bash
./scripts/revoke.sh alice s1 t1
```

Ожидаемый результат в режиме `reactive`:

- активный поток завершается после события
- повторная попытка открыть поток с тем же набором идентификаторов отклоняется

## Kubernetes-сценарий

Быстрый путь с уже собранными локальными image:

```bash
./scripts/kind_up.sh --mode both --skip-build
make install-metrics-server
make verify-mvp
```

Полный сценарий-обёртка:

```bash
./scripts/kind_up.sh --mode both
```

Полный сценарий-обёртка собирает кастомный образ Envoy и на холодном кэше может выполняться долго.
Начиная с текущей версии [scripts/kind_up.sh](scripts/kind_up.sh) не пересобирает все образы безусловно, а переиспользует локальные образы, если исходники не менялись. Для принудительной полной пересборки есть `--force-build`.
Для самого тяжёлого шага, сборки `reactive-mesh/envoy-reactive:dev`, теперь используется [scripts/build_envoy_image.sh](scripts/build_envoy_image.sh): он запускает `docker buildx build --load` с локальным кэшем в `.buildx-cache/` и повторно использует слои BuildKit между прогонами. Внутри [envoy/Dockerfile](envoy/Dockerfile) также включён постоянный кэш для `bazel`, поэтому повторная сборка после небольших изменений не должна начинаться почти с нуля.
Кроме того, [envoy/Dockerfile](envoy/Dockerfile) теперь разделён на `builder-base` и `builder`: стабильные слои с клонированием фиксированной версии Envoy, patch-скриптами и предзагрузкой зависимостей собираются отдельно, а каталог `reactive_pep/` копируется только в финальный этап сборки. Это позволяет собирать образ и в чистом checkout без локальных каталогов `envoy-src/` и `envoy/distfiles/`, а также уменьшает объём пересборки после правок в собственном фильтре.
Скрипт [scripts/kind_up.sh](scripts/kind_up.sh) также больше не зависит от записи в `~/.kube`: по умолчанию он использует локальный `KUBECONFIG` в `.tmp/kubeconfig`, что делает повторные прогоны воспроизводимыми и в изолированных средах.

Если нужно сбросить именно ускоряющий кэш Envoy, достаточно удалить `.buildx-cache/`:

```bash
rm -rf .buildx-cache
```

Основные публичные overlays сравнения:

- `deploy/kustomize/overlays/baseline-ext-authz`
- `deploy/kustomize/overlays/baseline-istio-custom`
- `deploy/kustomize/overlays/baseline-openfga`

Создание кластера вручную:

```bash
sudo kind create cluster --config deploy/kind/kind-config.yaml
```

Сборка и загрузка image:

```bash
sudo docker build -f receiver/Dockerfile -t reactive-mesh/receiver:dev .
sudo docker build -f grpc/server/Dockerfile -t reactive-mesh/grpc-server:dev .
sudo docker build -f grpc/client/Dockerfile -t reactive-mesh/grpc-client:dev .
sudo docker pull openpolicyagent/opa:latest-envoy-static
sudo docker tag openpolicyagent/opa:latest-envoy-static reactive-mesh/opa-envoy:dev
sudo docker build -f envoy/Dockerfile --build-arg ENVOY_CONFIG=envoy-reactive.yaml -t reactive-mesh/envoy-reactive:dev .
sudo docker build -f envoy/Dockerfile --build-arg ENVOY_CONFIG=envoy-baseline.yaml -t reactive-mesh/envoy-baseline:dev .
sudo kind load docker-image reactive-mesh/receiver:dev reactive-mesh/grpc-server:dev reactive-mesh/opa-envoy:dev reactive-mesh/envoy-reactive:dev reactive-mesh/envoy-baseline:dev --name reactive-mesh-authz
```

Развёртывание reactive overlay:

```bash
kubectl apply -k deploy/kustomize/overlays/reactive
```

Развёртывание базового overlay:

```bash
kubectl apply -k deploy/kustomize/overlays/baseline
```

Пример рендера Helm chart:

```bash
helm template reactive-mesh-authz deploy/helm/reactive-mesh-authz --set mode=reactive
```

Единая локальная проверка после развёртывания:

```bash
make install-metrics-server
make verify-mvp
cat experiments/results/verify-mvp/summary.json
```

Этот путь объединяет:

- проверку реактивного режима
- проверку режима сравнения через OPA-Envoy plugin
- проверку TLA+
- снимок накладных расходов
- метрики приёмника
- Envoy admin stats

Локальный прогон сценария GitHub Actions через `act` на уже собранных образах:

```bash
make ci-smoke-local
```

Скрипт для этого прогона:

- [scripts/run_act_smoke.sh](scripts/run_act_smoke.sh)

Горячая замена Envoy image в уже поднятом `kind`-кластере:

```bash
make redeploy-envoy
```

Скрипт для этого шага:

- [scripts/redeploy_envoy_images.sh](scripts/redeploy_envoy_images.sh)

## Формат события

Receiver принимает `POST /event`:

```json
{
  "event_type": "session-revoked",
  "event_id": "optional-id",
  "sub": "alice",
  "sid": "session-1",
  "jti": "token-1",
  "reason": "admin_logout",
  "ts": "2026-03-20T00:00:00Z"
}
```

Поддерживаемые типы событий:

- `session-revoked`
- `risk-deny`

Поддерживаемые варианты доставки:

- plain JSON body для текущих локальных сценариев проверки и стендовых прогонов
- compact JWS `HS256` через raw body или JSON-поле `set`, если заданы `JOSE_HS256_SECRET` и при необходимости `JOSE_REQUIRE_SIGNED=1`

Локальный helper для signed SET:

```bash
python3 scripts/make_signed_set.py \
  --secret secret123 \
  --event-type session-revoked \
  --sub alice \
  --sid s1 \
  --jti t1
```

## Метрики и оценка

Метрики приёмника:

- `receiver_events_total`
- `receiver_validation_failures_total`
- `receiver_duplicate_events_total`
- `receiver_state_queries_total`

Метрики базовой авторизации:

- `authorize_requests_total`
- `authorize_denies_total`
- `authorize_cache_hits_total`
- `authorize_refresh_total`

Выход benchmark:

- `latency_to_enforce_ms`
- `risk_window_ms`
- `risk_window_messages`
- `post_revoke_deny`
- `overhead_no_events`
- `false_termination_rate`
- `missed_revocation_rate`

Запуск benchmark:

```bash
python3 bench/load-client/run_benchmark.py \
  --client-binary /tmp/reactive-mesh-grpc-build/grpc-client \
  --grpc-addr localhost:8081 \
  --receiver-url http://localhost:8080/event \
  --mode reactive \
  --iterations 30 \
  --interval-ms 50 \
  --output experiments/results/reactive-medium.csv
```

Анализ результатов:

```bash
python3 experiments/analyze_results.py experiments/results/reactive-medium.csv
```

Короткий matrix-run по основным публичным архитектурам:

Примечание: в именах CSV для режима `OPA + Envoy` сохранён исторический префикс `baseline-ext_authz-*`.

```bash
./scripts/run_experiment_matrix.sh --iterations 1
python3 experiments/summarize_matrix.py \
  experiments/results/reactive-low.csv \
  experiments/results/reactive-medium.csv \
  experiments/results/reactive-high.csv \
  experiments/results/baseline-ext_authz-low.csv \
  experiments/results/baseline-ext_authz-medium.csv \
  experiments/results/baseline-ext_authz-high.csv \
  experiments/results/baseline-istio-custom-low.csv \
  experiments/results/baseline-istio-custom-medium.csv \
  experiments/results/baseline-istio-custom-high.csv \
  experiments/results/baseline-openfga-low.csv \
  experiments/results/baseline-openfga-medium.csv \
  experiments/results/baseline-openfga-high.csv
```

Текущие краткие артефакты, сохранённые в репозитории:

- reactive:
  [experiments/results/reactive-smoke.csv](experiments/results/reactive-smoke.csv)
- baseline:
  [experiments/results/baseline-smoke.json](experiments/results/baseline-smoke.json)
