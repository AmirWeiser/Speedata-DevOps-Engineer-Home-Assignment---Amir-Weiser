FROM python:3.12-slim-trixie

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY requirements.txt .
RUN pip install --require-hashes -r requirements.txt

COPY app.py ./
COPY templates/ templates/

# Numeric UID so Kubernetes runAsNonRoot can verify it without reading /etc/passwd.
USER 10001
EXPOSE 8080

# Same model as the backend: one worker, threads for I/O wait, scale with replicas.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--worker-class", "gthread", "--workers", "1", \
     "--threads", "4", "--timeout", "30", "--worker-tmp-dir", "/dev/shm", \
     "--access-logfile", "-", "app:create_app()"]
