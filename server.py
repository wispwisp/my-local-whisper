"""Минимальный HTTP-сервер поверх faster-whisper.

Эндпоинты:
  GET  /health
  POST /transcribe               multipart: file, language (en|ru|auto), prompt, verbatim (true|false)
  POST /v1/audio/transcriptions  совместим с OpenAI: file, model, language, prompt, response_format
"""
import io
import os
import time
import traceback

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse
from faster_whisper import WhisperModel

MODEL = os.getenv("MODEL", "large-v3-turbo")
DEVICE = os.getenv("DEVICE", "auto")                 # auto | cpu | cuda
COMPUTE_TYPE = os.getenv("COMPUTE_TYPE", "default")  # int8 на CPU, float16 на GPU
CPU_THREADS = int(os.getenv("CPU_THREADS", "0"))     # 0 = по умолчанию
BEAM_SIZE = int(os.getenv("BEAM_SIZE", "5"))
MODELS_DIR = os.getenv("MODELS_DIR", "/models")

# Подсказка в стиле "живой речи" склоняет Whisper к дословной записи (с паузами,
# словами-паразитами, оговорками), а не к причёсанному тексту. Не гарантия, но помогает.
VERBATIM_PROMPTS = {
    "en": "Umm, let me think like, hmm... Okay, here's what I'm, like, thinking.",
    "ru": "Эм, ну, это самое... короче, я, как бы, думаю так.",
}

t0 = time.time()
model = WhisperModel(
    MODEL,
    device=DEVICE,
    compute_type=COMPUTE_TYPE,
    cpu_threads=CPU_THREADS,
    download_root=MODELS_DIR,
)
print(f"model={MODEL} device={DEVICE} compute={COMPUTE_TYPE} loaded in {time.time() - t0:.1f}s", flush=True)

app = FastAPI(title="whisper-local")


@app.exception_handler(Exception)
async def on_error(request: Request, exc: Exception):
    # Полный трейсбек в лог контейнера, короткая причина — клиенту (вместо голого 500)
    tb = traceback.format_exc()
    print(tb, flush=True)
    return JSONResponse(status_code=500, content={"error": f"{type(exc).__name__}: {exc}", "traceback": tb})


def run(data: bytes, language: str | None, prompt: str | None, verbatim: bool) -> dict:
    if language in (None, "", "auto"):
        language = None
    if prompt is None and verbatim and language:
        prompt = VERBATIM_PROMPTS.get(language)

    segments, info = model.transcribe(
        io.BytesIO(data),
        language=language,
        beam_size=BEAM_SIZE,
        initial_prompt=prompt,
        condition_on_previous_text=False,  # меньше повторов и "самоубеждения" модели
        vad_filter=True,                   # режем тишину → меньше галлюцинаций
    )
    text = " ".join(s.text.strip() for s in segments).strip()
    return {
        "text": text,
        "language": info.language,
        "language_probability": round(info.language_probability, 3),
        "duration": round(info.duration, 2),
    }


@app.get("/health")
def health():
    return {"ok": True, "model": MODEL, "device": DEVICE, "compute_type": COMPUTE_TYPE}


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    language: str | None = Form(None),
    prompt: str | None = Form(None),
    verbatim: str = Form("true"),  # строка, а не bool: FastAPI трактует отсутствующее bool-поле формы как False
):
    return run(await file.read(), language, prompt, verbatim.lower() not in ("false", "0", "no", "off"))


@app.post("/v1/audio/transcriptions")
async def openai_transcriptions(
    file: UploadFile = File(...),
    model: str | None = Form(None),  # игнорируется: модель одна, задаётся через env
    language: str | None = Form(None),
    prompt: str | None = Form(None),
    response_format: str = Form("json"),
):
    result = run(await file.read(), language, prompt, verbatim=True)
    if response_format == "text":
        return PlainTextResponse(result["text"])
    if response_format == "verbose_json":
        return result
    return {"text": result["text"]}
