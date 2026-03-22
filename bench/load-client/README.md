# Запуск измерений

`run_benchmark.py` управляет существующим gRPC-клиентом, отправляет событие отзыва в момент `t_revoke` и записывает по одной CSV-строке на каждый прогон со следующими полями:

- `latency_to_enforce_ms`
- `risk_window_ms`
- `risk_window_ms_censored`
- `risk_window_messages`
- `post_revoke_deny`
- `still_running_after_observe`
- `observe_after_revoke_ms`
- исходный ответ приёмника

Интерпретация:

- `risk_window_ms` измеряет окно риска в миллисекундах.
- Если поток завершился в окне наблюдения, `risk_window_ms` совпадает со временем от отзыва до завершения.
- Если поток не завершился, `risk_window_ms_censored=1`, а `risk_window_ms` фиксирует нижнюю оценку окна риска по длительности окна наблюдения.

Пример:

```bash
python3 bench/load-client/run_benchmark.py \
  --client-binary /path/to/grpc-client \
  --grpc-addr localhost:8081 \
  --receiver-url http://localhost:8080/event \
  --mode reactive \
  --iterations 30 \
  --interval-ms 50 \
  --output experiments/results/reactive-low.csv
```
