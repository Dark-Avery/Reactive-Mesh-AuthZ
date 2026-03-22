# Эксперименты

Рекомендуемая матрица:

- профили: `low` (`interval-ms=200`), `medium` (`interval-ms=50`), `high` (`interval-ms=10`)
- основная матрица сравнения по проектам с открытым исходным кодом: `reactive`, `OPA + Envoy`, `Istio CUSTOM`, `OpenFGA`
- дополнительные локальные режимы внутренней проверки можно подключать отдельно при инженерной отладке
- повторения: `30` на каждую ячейку

Базовый сценарий работы:

1. Запустить `bench/load-client/run_benchmark.py` для каждой ячейки матрицы.
2. Сохранить CSV-файлы в `experiments/results/`.
3. Суммировать результаты через `python3 experiments/analyze_results.py experiments/results/<file>.csv`.
4. Построить ECDF / boxplot через `experiments/plot_results.py`, notebook или внешний инструмент построения графиков.

Автоматизированный пакетный прогон:

```bash
./scripts/run_experiment_matrix.sh --iterations 30
python3 experiments/summarize_matrix.py experiments/results/*.csv
```

## Интерактивный ноутбук

Для разбора результатов на уровне ВКР или статьи в репозитории добавлен ноутбук:

- [experiments/notebooks/reactive_mesh_analysis.ipynb](notebooks/reactive_mesh_analysis.ipynb)
- [experiments/requirements-notebook.txt](requirements-notebook.txt)

Он использует уже сохранённые CSV/JSON-артефакты из `experiments/results/` и позволяет:

- собрать основную сводку по проектам сравнения с открытым исходным кодом и при необходимости отдельно подключить локальные абляции;
- посмотреть окно риска по профилям нагрузки;
- построить boxplot для `latency_to_enforce_ms` в реактивном режиме;
- быстро подтянуть основные локальные результаты в один анализ.

Подготовка окружения:

```bash
make setup-notebook
source .venv-notebook/bin/activate
jupyter notebook
```
