FROM python:3.12-slim

# GPU=1 — доставить CUDA-рантайм (cuBLAS + cuDNN 9) pip'ом. Драйвер берётся с хоста
# через nvidia-container-toolkit, отдельный образ nvidia/cuda не нужен.
ARG GPU=0

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    MODELS_DIR=/models

# ffmpeg системный не нужен: faster-whisper декодирует аудио через PyAV со встроенными либами.
# av<19: PyAV 19 убрал av.open(metadata_errors=...), а faster-whisper 1.2.x его ещё передаёт → TypeError на каждом запросе
RUN pip install "faster-whisper>=1.1" "av<19" fastapi "uvicorn[standard]" python-multipart

RUN if [ "$GPU" = "1" ]; then pip install nvidia-cublas-cu12 "nvidia-cudnn-cu12==9.*"; fi
ENV LD_LIBRARY_PATH=/usr/local/lib/python3.12/site-packages/nvidia/cublas/lib:/usr/local/lib/python3.12/site-packages/nvidia/cudnn/lib

WORKDIR /app
COPY server.py .

EXPOSE 8000
# start-period большой: первый старт качает модель (1.5–3 ГБ)
HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')" || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]

