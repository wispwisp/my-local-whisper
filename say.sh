#!/usr/bin/env bash
# Записать речь с микрофона и получить текст от локального whisper.
#
#   ./say.sh            # английский, запись до нажатия q
#   ./say.sh ru         # русский
#   ./say.sh auto       # автоопределение языка (хуже с акцентом — может уйти в русский)
#   ./say.sh en 20      # английский, ровно 20 секунд
#
# Переменные окружения:
#   WHISPER_URL  (default http://127.0.0.1:8000)
#   MIC_INPUT    Linux: имя источника pulse/pipewire (default "default")
#   MIC_INDEX    macOS: индекс устройства avfoundation (default 0)
#                список: ffmpeg -f avfoundation -list_devices true -i ""
set -euo pipefail

LANG_CODE="${1:-en}"
DURATION="${2:-0}"
URL="${WHISPER_URL:-http://127.0.0.1:8000}"
WAV="${TMPDIR:-/tmp}/say_$$.wav"
trap 'rm -f "$WAV"' EXIT

command -v ffmpeg >/dev/null || { echo "нужен ffmpeg на хосте" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) INPUT=(-f avfoundation -i ":${MIC_INDEX:-0}") ;;
  Linux)  INPUT=(-f pulse -i "${MIC_INPUT:-default}") ;;
  *)      echo "неизвестная ОС: задай INPUT вручную в скрипте" >&2; exit 1 ;;
esac

LIMIT=()
if [ "$DURATION" -gt 0 ] 2>/dev/null; then
  LIMIT=(-t "$DURATION")
  echo "REC ${DURATION}s..." >&2
else
  echo "REC... (q — стоп)" >&2
fi

ffmpeg -hide_banner -loglevel error "${INPUT[@]}" "${LIMIT[@]}" -ac 1 -ar 16000 -y "$WAV"

LANG_ARG=()
[ "$LANG_CODE" != "auto" ] && LANG_ARG=(-F "language=$LANG_CODE")

RESP="$(curl -sS "$URL/transcribe" -F "file=@$WAV" "${LANG_ARG[@]}" -w $'\n%{http_code}')"
CODE="${RESP##*$'\n'}"
BODY="${RESP%$'\n'*}"

if [ "$CODE" != "200" ]; then
  echo "сервер ответил $CODE:" >&2
  printf '%s\n' "$BODY" | python3 -c '
import sys, json
s = sys.stdin.read()
try:
    d = json.loads(s); print(d.get("error", d)); print(d.get("traceback", ""), end="")
except Exception:
    print(s)' >&2
  [ -n "${KEEP:-}" ] && { trap - EXIT; echo "запись оставлена: $WAV" >&2; }   # KEEP=1 ./say.sh — не удалять wav при ошибке
  exit 1
fi

printf '%s\n' "$BODY" | python3 -c 'import sys, json; print(json.load(sys.stdin)["text"])'
