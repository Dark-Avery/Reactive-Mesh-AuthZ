# Документация проекта

Этот каталог собирает исследовательскую и эксплуатационную документацию по стенду `Reactive Mesh AuthZ`.

## Что читать в первую очередь

- [architecture/README.md](architecture/README.md) — состав компонентов, поток событий и модель идентификаторов
- [evaluation/README.md](evaluation/README.md) — матрица экспериментов, единая локальная проверка и локальный сценарий CI
- [related-work/README.md](related-work/README.md) — границы новизны и сравнение с OSS-проектами

## Статус и приёмка

- [../experiments/results/matrix-report-full.json](../experiments/results/matrix-report-full.json) — агрегированный статистический отчёт по полной матрице сравнений
- [../experiments/results/final-experiment-summary.json](../experiments/results/final-experiment-summary.json) — компактный итоговый пакет экспериментальных результатов

Локальные папки проверки, временные логи и одноразовые приёмочные артефакты в GitHub-версию репозитория не входят. В репозитории сохраняются только центральные результаты, графики и исходные данные, на которые опирается итоговая работа.

## Быстрый проверяемый путь

Если нужно быстро понять, закрыт ли стенд в текущем рабочем каталоге, достаточно трёх шагов:

```bash
make install-metrics-server
make verify-mvp
cat experiments/results/verify-mvp/summary.json
cat experiments/results/verify-mvp/correctness-report.json
```

Что именно это даёт:

- проверку реактивного режима
- проверку основного режима сравнения
- проверку трёх основных архитектур сравнения
- прогон TLA+ проверки
- снимок накладных расходов во время выполнения
- отчёт о корректности применения политики
- сбор метрик приёмника и Envoy

Если нужна отдельная проверка именно по реальным open-source архитектурам, используйте:

```bash
./scripts/verify_oss_comparators.sh
cat experiments/results/verify-oss-comparators/summary.json
```

Этот сценарий подтверждает:

- OPA + Envoy
- Istio CUSTOM
- OpenFGA

Основная публичная часть документации строится вокруг трёх основных архитектур с открытым исходным кодом:

- `OPA + Envoy`
- `Istio CUSTOM`
- `OpenFGA`

Они покрывают три архитектурные линии: внешнюю авторизацию на уровне прокси, внешнюю авторизацию в сервисной сетке и централизованную детализированную авторизацию. Дополнительные локальные абляции остаются только как вспомогательные инженерные проверки.

## Связанные каталоги

- [../experiments/README.md](../experiments/README.md) — запуск matrix-run и работа с результатами
- [../experiments/notebooks/reactive_mesh_analysis.ipynb](../experiments/notebooks/reactive_mesh_analysis.ipynb) — интерактивный ноутбук для разбора уже сохранённых в репозитории результатов
- [../formal/tla/ReactiveMeshAuthZ.tla](../formal/tla/ReactiveMeshAuthZ.tla) — формальная модель
- [../README.md](../README.md) — общая инструкция запуска и проверки
