FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY hk-relay/hk_relay.py /app/hk_relay.py

USER nobody
EXPOSE 9000

CMD ["python3", "/app/hk_relay.py"]

