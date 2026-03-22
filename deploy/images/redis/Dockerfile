FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    redis-server && \
    rm -rf /var/lib/apt/lists/*

EXPOSE 6379

CMD ["redis-server", "--save", "", "--appendonly", "no"]
