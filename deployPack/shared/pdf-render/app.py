"""
pdf-render — sidecar-сервис для n8n.

GET /render?file=<имя.pdf>&dpi=200&max_pages=4&autorotate=1
  Читает PDF из /data/docs (read-only монтирование NAS),
  растрирует страницы в PNG и возвращает их в base64 —
  готово для передачи в Ollama vision-модель (qwen3-vl).

autorotate (по умолчанию 1): если на первой странице текст вертикальный
(скан альбомной таблицы на портретном листе), страницы поворачиваются
так, чтобы текст читался горизонтально:
  1. CV-эвристика по профилям проекций решает, вертикальный ли текст;
  2. рендерится кандидат (поворот 270° CCW — самый частый случай);
  3. VLM (qwen3-vl:8b через Ollama, превью 1536px) бинарно проверяет
     читаемость кандидата; не читается -> поворот 90° CCW;
     Ollama недоступна -> остаётся 270°.
В ответе поле `rotation` — применённый поворот в градусах CCW (0 = не крутили).
"""

import base64
import io
import json
import os
import urllib.request
from pathlib import Path

import pypdfium2 as pdfium
from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from PIL import Image

DOCS_DIR = Path(os.environ.get("DOCS_DIR", "/data/docs"))
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "ollama:11434")
ORIENT_MODEL = os.environ.get("ORIENT_MODEL", "qwen3-vl:8b-instruct-q8_0")

app = FastAPI(title="pdf-render")


@app.get("/health")
def health():
    return {"status": "ok", "docs_dir": str(DOCS_DIR)}


# ------------------------------------------------------------
# CV-эвристика: вертикальный ли текст на странице.
# У горизонтального текста «пилу» даёт проекция на строки,
# у вертикального — на столбцы. Pure PIL, без numpy.
# ------------------------------------------------------------
def text_is_vertical(im: Image.Image) -> bool:
    g = im.convert("L")
    g.thumbnail((600, 600))
    w, h = g.size
    px = g.load()
    row = [0] * h
    col = [0] * w
    for y in range(h):
        for x in range(w):
            if px[x, y] < 128:
                row[y] += 1
                col[x] += 1

    def roughness(p):
        mean = sum(p) / len(p) or 1e-9
        diff = sum(abs(p[i + 1] - p[i]) for i in range(len(p) - 1)) / (len(p) - 1)
        return diff / mean

    return roughness(col) > roughness(row) * 1.15


# ------------------------------------------------------------
# VLM-проверка: читается ли страница (текст горизонтально, слева направо).
# Сбой Ollama -> True (не мешаем пайплайну, остаётся кандидат по умолчанию).
# ------------------------------------------------------------
def vlm_readable(im: Image.Image) -> bool:
    # Превью 1536px: при 768px текст УПД слишком мелкий, и даже 7b-модель
    # не может определить ориентацию (проверено на живом скане 2026-10-02).
    thumb = im.copy()
    thumb.thumbnail((1536, 1536))
    buf = io.BytesIO()
    thumb.save(buf, format="PNG")
    b64 = base64.b64encode(buf.getvalue()).decode("ascii")
    payload = {
        "model": ORIENT_MODEL,
        "think": False,
        "stream": False,
        "format": {
            "type": "object",
            "properties": {"readable": {"type": "boolean"}},
            "required": ["readable"],
            "additionalProperties": False,
        },
        "options": {"temperature": 0, "num_ctx": 8192},
        "messages": [
            {"role": "system", "content":
             "Посмотри на страницу документа. Если основной текст страницы написан горизонтально "
             "и читается слева направо (как обычная книга) — ответь readable=true. "
             "Если текст перевёрнут вверх ногами или повёрнут боком — readable=false. "
             "Ответ строго JSON."},
            {"role": "user", "content": "Проверь читаемость страницы.", "images": [b64]},
        ],
    }
    try:
        req = urllib.request.Request(
            f"http://{OLLAMA_HOST}/api/chat",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            out = json.loads(resp.read().decode("utf-8"))
        return bool(json.loads(out["message"]["content"])["readable"])
    except Exception:
        return True


def decide_rotation(first_page: Image.Image) -> int:
    """0 — не крутить; 90/270 — поворот CCW для вертикального текста."""
    if not text_is_vertical(first_page):
        return 0
    candidate = first_page.rotate(270, expand=True)   # самый частый случай
    return 270 if vlm_readable(candidate) else 90


@app.get("/render")
def render(
    file: str = Query(..., description="Имя PDF-файла в /data/docs"),
    dpi: int = Query(200, ge=72, le=400),
    max_pages: int = Query(4, ge=1, le=20),
    autorotate: int = Query(1, ge=0, le=1),
):
    # Защита от path traversal: берём только имя файла, без каталогов.
    name = Path(file).name
    path = DOCS_DIR / name
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"file not found: {name}")

    # Читаем файл в память: pdfium при открытии по пути mmap'ит файл,
    # что на CIFS-монтировании (NAS) может падать. Bytes-режим надёжнее.
    try:
        raw = path.read_bytes()
    except OSError as e:
        raise HTTPException(status_code=500, detail=f"cannot read file: {e}")
    return _render_to_response(raw, name, dpi, max_pages, autorotate)


# ------------------------------------------------------------
# POST /render-upload — для eval (tests/run_eval.py): PDF приходит байтами,
# шара и очередь не участвуют, продовая база не загрязняется.
# ------------------------------------------------------------
@app.post("/render-upload")
async def render_upload(
    file: UploadFile = File(...),
    dpi: int = Query(200, ge=72, le=400),
    max_pages: int = Query(2, ge=1, le=20),
    autorotate: int = Query(1, ge=0, le=1),
):
    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=422, detail="empty upload")
    return _render_to_response(raw, Path(file.filename or "upload.pdf").name,
                               dpi, max_pages, autorotate)


# ------------------------------------------------------------
# Общий путь: байты PDF -> страницы PNG (base64) + autorotate.
# ------------------------------------------------------------
def _render_to_response(raw: bytes, name: str, dpi: int, max_pages: int, autorotate: int):
    try:
        pdf = pdfium.PdfDocument(raw)
    except Exception as e:
        raise HTTPException(status_code=422, detail=f"cannot parse PDF: {e}")
    try:
        total_pages = len(pdf)
        n = min(total_pages, max_pages)
        scale = dpi / 72.0
        images = []
        for i in range(n):
            page = pdf[i]
            try:
                images.append(page.render(scale=scale).to_pil())
            finally:
                page.close()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"render failed on file {name}: {e}")
    finally:
        pdf.close()

    rotation = 0
    if autorotate and images:
        try:
            rotation = decide_rotation(images[0])
        except Exception:
            rotation = 0   # эвристика не должна валить пайплайн
    if rotation:
        images = [im.rotate(rotation, expand=True) for im in images]

    pages = []
    for im in images:
        buf = io.BytesIO()
        im.save(buf, format="PNG")
        pages.append(base64.b64encode(buf.getvalue()).decode("ascii"))

    return {
        "file": name,
        "total_pages": total_pages,
        "rendered_pages": n,
        "rotation": rotation,
        "pages": pages,
    }
