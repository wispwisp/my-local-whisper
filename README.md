# my-local-whisper

Локальный Whisper в Docker на базе [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (CTranslate2).
Сценарий: надиктовал промпт по-английски → получил текст → отдал на проверку грамматики.

## Что внутри

| Файл | Назначение |
|---|---|
| `Dockerfile` | python:3.12-slim + faster-whisper + FastAPI; при `GPU=1` добавляет cuBLAS/cuDNN 9 через pip |
| `compose.yml` | два профиля: `gpu` (large-v3, float16) и `cpu` (large-v3-turbo, int8) |
| `server.py` | HTTP-сервер: `/transcribe` и OpenAI-совместимый `/v1/audio/transcriptions` |
| `say.sh` | запись с микрофона (ffmpeg) → сервер → текст в stdout |

## Требования

- Docker с Compose v2.
- GPU-профиль: NVIDIA-драйвер с поддержкой CUDA 12 (≥ 525) + [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html). Проверка: `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`.
- Для `say.sh` на хосте: `ffmpeg`, `curl`, `python3`.

## Запуск

```bash
docker compose --profile gpu up -d --build    # NVIDIA
docker compose --profile cpu up -d --build    # без GPU
docker compose logs -f                         # первый старт качает модель: turbo ~1.6 ГБ, large-v3 ~3 ГБ
curl -s localhost:8000/health
```

Модели кэшируются в `./models`, повторный запуск не качает.

Сменить модель: `MODEL=large-v3 docker compose --profile cpu up -d`. Варианты: `large-v3`, `large-v3-turbo`, `medium`, либо любой CTranslate2-репозиторий с Hugging Face (`Systran/...`, `deepdml/...`).

## Использование

```bash
chmod +x say.sh
./say.sh            # английский; говори, по окончании нажми q
./say.sh ru         # русский
./say.sh en 15      # 15 секунд без нажатий
./say.sh auto       # автоопределение языка
```

Через API напрямую:

```bash
curl -s localhost:8000/transcribe -F file=@clip.wav -F language=en
# {"text": "...", "language": "en", "language_probability": 0.99, "duration": 12.3}

curl -s localhost:8000/transcribe -F file=@clip.wav -F language=en -F verbatim=false   # без "дословной" подсказки
curl -s localhost:8000/transcribe -F file=@clip.wav -F language=en -F prompt="Docker, Kubernetes, FastAPI"  # своя подсказка — помогает с терминами
```

OpenAI-совместимый эндпоинт — подходит для любых клиентов с `base_url`:

```bash
curl -s localhost:8000/v1/audio/transcriptions -F file=@clip.wav -F model=whisper-1 -F language=en -F response_format=text
```

Цикл «сказал → проверил» одной строкой, если под рукой любой CLI к LLM (пример с Claude Code):

```bash
./say.sh | claude -p "Below is a transcript of my spoken English. List grammar and word-choice mistakes, give the corrected version, then a more natural phrasing."
```

Windows: `say.sh` рассчитан на Linux/macOS. В PowerShell запись делается так:
`ffmpeg -f dshow -i audio="Microphone name" -t 15 -ac 1 -ar 16000 clip.wav` (имя устройства — `ffmpeg -list_devices true -f dshow -i dummy`), дальше `curl.exe` как выше. Из WSL2 микрофон недоступен.

## Почему такие дефолты

- **Язык задаётся явно (`en`).** С русским акцентом автодетект иногда решает, что это русский, и выдаёт кириллицу или смесь. `auto` оставлен для случаев, когда реально неизвестно.
- **GPU → `large-v3`, CPU → `large-v3-turbo`.** На русском turbo близок к полной модели, но на коротких фразах чаще галлюцинирует и в целом чуть хуже на не-английских языках. На GPU разница во времени — доли секунды, поэтому полная модель. На CPU turbo в ~4 раза быстрее (ориентир: фраза в 15 с — несколько секунд на turbo int8, десятки секунд на large-v3).
- **`condition_on_previous_text=False`, `vad_filter=True`.** Меньше зацикливания и выдуманного текста на паузах.
- **«Дословная» подсказка (`initial_prompt`).** Whisper обучен на причёсанных субтитрах и по умолчанию убирает «э-э», оговорки, а иногда **сам исправляет грамматику**. Для твоей цели это вредно: ошибка в речи может не дойти до проверки. Подсказка со словами-паразитами заметно снижает этот эффект, но полностью не убирает — считай транскрипт «почти дословным».

## Ограничения и что ещё можно сделать

- Стопроцентной дословности от Whisper не получить. Если захочется строже — есть CrisperWhisper (дообучение на дословную запись, но только английский/немецкий; под CT2 пришлось бы конвертировать самому). Предположение: для твоего сценария хватит текущей связки, а грубые ошибки (времена, артикли, порядок слов) она в основном сохраняет.
- Русские дообучения Whisper (`antony66/whisper-large-v3-russian`, `bond005/...`) дают заметный выигрыш на русском, но это HF-формат (нужна конвертация в CT2), и есть риск просадки на английском. Для двуязычного использования лучше базовый large-v3.
- macOS с Apple Silicon: Docker не видит GPU, будет CPU. Если скорость не устроит — нативно `whisper.cpp` (Metal) или `mlx-whisper` быстрее в разы.
- Тонкая настройка через env: `BEAM_SIZE` (1 — быстрее, 5 — точнее), `CPU_THREADS`, `MODEL`.

