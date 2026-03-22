# План оценки

## Основные метрики

- `latency_to_enforce_ms`
- `risk_window_ms`
- `risk_window_ms_censored`
- `risk_window_messages`
- `post_revoke_deny`
- `overhead_no_events`
- `false_termination_rate`
- `missed_revocation_rate`
- `receiver_events_total`
- `receiver_validation_failures_total`
- `authorize_denies_total`
- `pep_termination_total`
- `active_streams`
- CPU / memory overhead через `kubectl top`

Для baseline-сравнения в итоговых артефактах явно закрываются все обязательные метрики:

- `latency_to_enforce_ms`
- `risk window Δ` в миллисекундах через `risk_window_ms`
- `risk window Δ_messages` через `risk_window_messages`
- `post_revoke_deny`
- `overhead_no_events`
- `false_termination_rate`
- `missed_revocation_rate`

Их компактное проверяемое представление вынесено в [experiments/results/final-experiment-summary.json](../../experiments/results/final-experiment-summary.json), а детальная статистика по профилям и доверительным интервалам находится в [experiments/results/matrix-report-full.json](../../experiments/results/matrix-report-full.json).

## Единая локальная проверка

Для локальной воспроизводимой проверки стенда в репозитории есть единый сценарий:

```bash
make install-metrics-server
make verify-mvp
```

Или напрямую:

```bash
./scripts/install_metrics_server.sh
./scripts/verify_mvp.sh
```

Сценарий [scripts/verify_mvp.sh](../../scripts/verify_mvp.sh) выполняет:

- короткую реактивную проверку
- проверку базового открытого контура сравнения `OPA + Envoy`
- проверку `Istio CUSTOM`
- проверку `OpenFGA`
- проверку модели TLA+
- снимок накладных расходов
- генерацию отчёта о корректности
- сбор метрик приёмника
- сбор административной статистики Envoy

Этот сценарий является локальной проверкой готовности стенда. Его выходные файлы считаются временными и в GitHub-версию репозитория не входят.

Основной сценарий многократного прогона [scripts/run_experiment_matrix.sh](../../scripts/run_experiment_matrix.sh) запускает режимы через единый путь с bearer token:

- локальный OSS OIDC/JWKS IdP
- один и тот же gRPC-клиент
- один и тот же сценарий отзыва
- одинаковые `sub/sid/jti`, извлечённые из токена

Он специально сделан как быстрый локальный критерий готовности стенда и CI. Для публикации в репозитории используются не временные файлы проверки, а центральные сводные артефакты полного набора результатов.

## Локальный прогон CI-сценария

Для репликации GitHub Actions в локальной среде добавлена обёртка:

```bash
make ci-smoke-local
```

или напрямую:

```bash
./scripts/run_act_smoke.sh
```

Он запускает [.github/workflows/kind-smoke.yml](../../.github/workflows/kind-smoke.yml) через `act` и использует уже собранные локальные Docker-образы.

Этот путь предназначен для локальной репликации сценария `kind-smoke`. Отдельно стоит отличать его от внешнего публичного прогона в GitHub Actions: он зависит уже не от репозитория как такового, а от внешнего CI-окружения.

Сам `kind-smoke` CI должен собирать только релизно-значимые компоненты стенда:

- `receiver`
- `baseline-authz`
- `grpc-server`
- `redis`
- `demo-idp`
- `openfga`
- `opa-envoy`
- `envoy-reactive`
- `envoy-baseline`

Для подтверждения `Istio CUSTOM` сценарий дополнительно подтягивает официальные образы Istio во время самой короткой проверки.

Он не должен собирать полный многократный датасет, локальные каталоги проверки, дипломные PDF и другие необязательные исследовательские артефакты.

## Матрица экспериментов

- режимы:
- `reactive`
- `OPA + Envoy` как основной открытый контур авторизации в момент запроса
- `Istio CUSTOM` как открытый контур сравнения в сервисной сетке
- `OpenFGA` как основной открытый централизованный контур сравнения
- дополнительные локальные проверки используются только вне основной публичной секции сравнения
- профили нагрузки: low (`200ms`), medium (`50ms`), high (`10ms`)
- повторения: `30` на конфигурацию

## Центральные артефакты, сохранённые в репозитории

- основной сводный набор результатов: [experiments/results/matrix-summary-full.json](../../experiments/results/matrix-summary-full.json)
- агрегированный статистический отчёт: [experiments/results/matrix-report-full.json](../../experiments/results/matrix-report-full.json)
- итоговый компактный JSON-отчёт: [experiments/results/final-experiment-summary.json](../../experiments/results/final-experiment-summary.json)
- основные графики:
  - [experiments/results/plots/oss_risk_window_by_profile.png](../../experiments/results/plots/oss_risk_window_by_profile.png)
  - [experiments/results/plots/oss_gap_vs_reactive.png](../../experiments/results/plots/oss_gap_vs_reactive.png)
  - [experiments/results/plots/reactive_latency_by_profile.png](../../experiments/results/plots/reactive_latency_by_profile.png)
- краткие артефакты для быстрой проверки:
  - [experiments/results/reactive-smoke.csv](../../experiments/results/reactive-smoke.csv)
  - [experiments/results/baseline-smoke.json](../../experiments/results/baseline-smoke.json)
- интерактивный ноутбук для работы с уже сохранёнными в репозитории результатами:
  [experiments/notebooks/reactive_mesh_analysis.ipynb](../../experiments/notebooks/reactive_mesh_analysis.ipynb)
- зависимости для ноутбука:
  [experiments/requirements-notebook.txt](../../experiments/requirements-notebook.txt)
- автоматизированная подготовка окружения для ноутбука:
  `make setup-notebook`
## Рекомендуемая структура отчёта

1. Тестовый стенд и режим развёртывания.
2. Формат событий и связывание идентификаторов.
3. p50 / p95 / p99 и 95% CI.
4. Сравнение ECDF и boxplot.
5. False terminations и missed revocations.
6. Накладные расходы при отсутствии revoke-событий.
7. Проверяемость локального стенда одной командой.

## Что ещё нужно для полноценной оценки уровня статьи или ВКР

- зафиксировать точные hardware / runtime условия для воспроизводимости

Часть с агрегированным статистическим сравнением уже формализована в:

- [experiments/results/matrix-report-full.json](../../experiments/results/matrix-report-full.json)

Текущий воспроизводимый сценарий:

Примечание: в именах CSV для этого режима сохранён исторический префикс `baseline-ext_authz-*`, но в тексте работы и на графиках он везде называется `OPA + Envoy`.

```bash
./scripts/run_experiment_matrix.sh --iterations 30
python3 experiments/summarize_matrix.py experiments/results/reactive-low.csv experiments/results/reactive-medium.csv experiments/results/reactive-high.csv experiments/results/baseline-ext_authz-low.csv experiments/results/baseline-ext_authz-medium.csv experiments/results/baseline-ext_authz-high.csv experiments/results/baseline-istio-custom-low.csv experiments/results/baseline-istio-custom-medium.csv experiments/results/baseline-istio-custom-high.csv experiments/results/baseline-openfga-low.csv experiments/results/baseline-openfga-medium.csv experiments/results/baseline-openfga-high.csv
python3 experiments/plot_matrix.py --summary experiments/results/matrix-summary-full.json --reactive-csvs experiments/results/reactive-low.csv experiments/results/reactive-medium.csv experiments/results/reactive-high.csv --outdir experiments/results/plots
python3 experiments/prepare_final_results.py
```
