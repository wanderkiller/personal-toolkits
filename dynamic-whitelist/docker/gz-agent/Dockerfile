FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends nftables \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY gz-agent/gz_agent.py /app/gz_agent.py

VOLUME ["/data"]

CMD ["python3", "/app/gz_agent.py"]

