FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    openssl && \
    rm -rf /var/lib/apt/lists/*
COPY app.py .
EXPOSE 8080
CMD ["python3", "/app/app.py"]
