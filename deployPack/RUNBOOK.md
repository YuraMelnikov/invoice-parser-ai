# RUNBOOK — развёртывание и эксплуатация

Стек этапа 1: postgres, n8n, ollama, qdrant, pgadmin, pdf-render.
Compose-файл — `docker-compose.yml` в корне проекта, все команды — из корня.

## 1. Требования к хосту

- Docker с compose-плагином (`docker compose version` отвечает без ошибок).
- Доступ к SMB-шаре `//192.168.1.30/m/Приходные накладные/AI` (монтируется
  как volume `docs_ai`, в контейнерах — `/data/docs`, read-only для pdf-render).
- Для GPU-профилей: NVIDIA (nvidia-container-toolkit) или AMD ROCm.

## 2. Переменные окружения

`.env` в корне (секреты, не коммитить). Используются:

```
POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
N8N_ENCRYPTION_KEY, N8N_USER_MANAGEMENT_JWT_SECRET
SMB_USER, SMB_PASS                  # доступ к шаре с накладными
PGADMIN_EMAIL, PGADMIN_PASSWORD     # опционально, есть дефолты
OLLAMA_HOST                         # опционально, дефолт ollama:11434
```

## 3. Запуск

Ollama и init-контейнеры — за профилями; без профиля Ollama не поднимется:

```bash
# CPU:
docker compose --profile cpu up -d

# NVIDIA GPU:
docker compose --profile gpu-nvidia up -d

# AMD GPU:
docker compose --profile gpu-amd up -d
```

Init-контейнер (`ollama-pull-models`) дожидается Ollama и тянет модели
`qwen3-vl:8b`, `qwen3:8b`, `bge-m3` (ADR-0001), затем завершается —
это нормально. Прогресс: `docker logs -f ollama-pull-models`.
Проверка: `docker exec ollama ollama list`.

Схема `docs.*` накатывается автоматически только при ПЕРВОМ старте на пустом
`postgres_storage`. Перенакат на живой базе:

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -f /docker-entrypoint-initdb.d/001_schema.sql
```

## 4. Проверка после старта

```bash
docker compose ps                                   # все (healthy)/running
curl http://localhost:8000/health                   # pdf-render: {"status":"ok",...}
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dt docs.*"'   # 3 таблицы
```

Проверка autorotate на эталоне (скопировать `tests/fixtures/test_03.pdf`
на шару, затем):

```bash
curl "http://localhost:8000/render?file=test_03.pdf&max_pages=1" | python -c "import sys,json; print('rotation:', json.load(sys.stdin)['rotation'])"
# ожидаем rotation: 270 — подтверждает и CV-эвристику, и VLM-ветку (qwen3-vl:8b)
```

Статус: **прогнано на живом хосте 2026-10-06, все проверки пройдены**
(rotation: 270; postgres — 3 таблицы docs.*; ollama — qwen3-vl:8b, qwen3:8b,
bge-m3; n8n/qdrant — HTTP 200). Учитывать: первый рендер после старта —
~90 с (холодная модель в Ollama), не путать с зависанием; HTTP-таймауты
клиента ставить от 240 с.

### Подключение pgAdmin к Postgres

Логин в UI pgAdmin — `PGADMIN_EMAIL` / `PGADMIN_PASSWORD` из `.env`
(дефолт `admin@katek.local` / `pgadmin`); креденшелы фиксируются при первом
старте volume `pgadmin_storage` — смена `.env` на живом volume не действует.

Сервер в pgAdmin: Host = `postgres` (имя контейнера в сети `katek_lab`,
НЕ localhost), Port = `5432`, Maintenance DB / Username / Password =
`POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` из `.env`.
Симптом неверного хоста/пароля — 401 на `POST /browser/server/obj/...`
в логах pgadmin.

## 5. Порты (доступ с хоста)

| Сервис | Порт |
| --- | --- |
| n8n | 5678 |
| pdf-render | 8000 |
| Postgres | 5432 |
| pgAdmin | 8080 |
| Qdrant | 6333 |
| Ollama | 11434 |

## 6. Eval качества распознавания

```bash
python tests/run_eval.py     # эталоны -> живые pdf-render + Ollama, сверка с expected
```

Промт общий с продовым worker (`shared/prompts/extract_items_system.txt`) —
правка промта не требует реимпорта workflow. Правила и формат — в
`tests/README.md`. Добавление нового эндпоинта `/render-upload` в pdf-render
требует пересборки: `docker compose up -d --build pdf-render`.

## 7. E2E-проверка пайплайна (задача 001, DoD)

Предусловия: миграция `002_archived_at.sql` накатана, три workflow
(`Invoice-001_Dispatcher`, `Invoice-002_Worker`, `Invoice-003_Archive`)
импортированы и активны, webhook воркера — Respond Immediately.

SQL выполнять так: `docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "..."`.

**Шаг 0.** Положить тестовый PDF на шару (`\\192.168.1.30\m\Приходные накладные\AI`).
Засечь время. Дальше — ждать: стабильность файла 3 мин + тик диспетчера
10 мин → захват в течение ~15 мин; обработка 400 dpi — до ~10 мин;
архивация — тик 5 мин.

**Шаг 1. Регистрация (dispatcher).** Строка появилась, затем status=new → processing:

```sql
SELECT file_name, status, file_size, file_mtime, status_changed_at
FROM docs.documents ORDER BY id DESC LIMIT 5;
```

**Шаг 2. Обработка (worker).** status=done, позиции на месте:

```sql
SELECT file_name, status, processed_at, error_message
FROM docs.documents WHERE file_name = 'ИМЯ_ФАЙЛА.pdf';

SELECT ii.line_no, ii.item_name, ii.unit, ii.quantity, ii.price
FROM docs.invoice_items ii
JOIN docs.invoices i ON i.id = ii.invoice_id
WHERE i.file_name = 'ИМЯ_ФАЙЛА.pdf'
ORDER BY ii.line_no;
```

Полный ответ модели: `SELECT raw_json FROM docs.invoices WHERE file_name = '...';`

**Шаг 3. Архивация (archive).** Файл ушёл в `_archive\`, отметка стоит:

```sql
SELECT file_name, status, archived_at FROM docs.documents
WHERE file_name = 'ИМЯ_ФАЙЛА.pdf';
```

**Шаг 4. Негатив.** Положить битый/непрофильный PDF → ждать → status=error,
`error_message` заполнено, файл перенесён в `_error\`:

```sql
SELECT file_name, status, error_message, archived_at FROM docs.documents
WHERE status = 'error' ORDER BY id DESC LIMIT 3;
```

**Шаг 5. Идемпотентность.** Положить тот же файл повторно → после цикла
проверить отсутствие дублей:

```sql
SELECT invoice_id, line_no, count(*)
FROM docs.invoice_items GROUP BY 1, 2 HAVING count(*) > 1;
-- пусто = дублей нет
```

## 8. Траблшутинг

- **Volume `docs_ai` не монтируется** — проверить `SMB_USER`/`SMB_PASS` и
  доступность шары с хоста; ошибка видна в `docker compose up` при старте
  n8n/pdf-render.
- **`docker compose ps` показывает pdf-render unhealthy** —
  `docker logs pdf-render`; чаще всего недоступен `/data/docs` (см. выше).
- **Модели не докачались** — перезапустить init:
  `docker compose --profile <cpu|gpu-nvidia|gpu-amd> up -d ollama-pull-models`.
- **Эвристика поворота ведёт себя странно на новом типе скана** — параметры
  `/render`: `autorotate=0` отключает поворот; модель проверки меняется
  переменной `ORIENT_MODEL` (дефолт `qwen3-vl:8b-instruct-q8_0`).

## 9. Стоп / откат

```bash
docker compose --profile cpu down     # данные в volume'ах сохраняются
```

Удаление volume'ов (`down -v`) — деструктивно, только по явной инструкции
владельца (AGENTS.md, красная граница).

## 10. Линковка с ERP (задача 002, ADR-0004)

Workflow: `Invoice-004_Embeddings` (позиции → Qdrant, тик 10 мин),
`Invoice-005_SKU-sync` (полный рефреш справочника ERP → `sku_catalog`,
тик 1 ч), `Invoice-006_Matcher` (гибрид: артикул+вето+вектор, тик 10 мин).

**Неслинкованное** (отработано матчером, но кода нет):

```sql
SELECT ii.id, i.file_name, ii.line_no, ii.item_name, ii.link_score
FROM docs.invoice_items ii
JOIN docs.invoices i ON i.id = ii.invoice_id
WHERE ii.link_processed = true AND ii.sku_code IS NULL
ORDER BY ii.link_score DESC;
```

**Все связи с методом** (`article` — точное совпадение артикула,
`vector` — семантика ≥ T1):

```sql
SELECT i.file_name, ii.line_no, ii.item_name,
       ii.sku_code, ii.link_method, ii.link_score
FROM docs.invoice_items ii
JOIN docs.invoices i ON i.id = ii.invoice_id
ORDER BY ii.id DESC;
```

**Ручная долинковка** (код из справочника ERP):

```sql
UPDATE docs.invoice_items
SET sku_code = 'КОД', link_method = 'manual', link_processed = true
WHERE id = …;
```

**Контроль рефреша справочника:** в n8n — последний execution
`Invoice-005_SKU-sync`, выход узла «Delete stale»
(`sku_total ≈ 365`, `stale_deleted`); из хоста:
`curl http://localhost:6333/collections/sku_catalog` → `points_count`.

## 11. Экспорт в ERP MS SQL (задача 004, ADR-0005)

Workflow: `Invoice-007_ERP-export` (тик 5 мин, батч 10 накладных).
Пишет в `exportImport.dbo.invoices` / `exportImport.dbo.invoice_items`;
таблицы создаёт сам workflow (идемпотентный DDL на каждом тике).
Выгружаются накладные, у которых ВСЕ позиции отработаны матчером
(`link_processed = true`); `exported_at` в `docs.invoices` — метка
«выгружено», сбрасывается триггером при delete+insert позиций
воркером (переобработка → перевыгрузка, в ERP замена по `file_name`).

**Очередь на выгрузку** (то, что заберёт ближайший тик):

```sql
SELECT i.id, i.file_name
FROM docs.invoices i
WHERE i.exported_at IS NULL
  AND EXISTS (SELECT 1 FROM docs.invoice_items ii
               WHERE ii.invoice_id = i.id AND ii.link_processed = true)
  AND NOT EXISTS (SELECT 1 FROM docs.invoice_items ii
                   WHERE ii.invoice_id = i.id AND ii.link_processed IS NOT TRUE)
ORDER BY i.id;
```

**Сверка PG ↔ ERP по накладной** (MS SQL, имя файла подставить):

```sql
SELECT ii.id, ii.invoice_id, ii.line_no, ii.item_name,
       ii.unit, ii.quantity, ii.price, ii.sku_code
FROM exportImport.dbo.invoice_items ii
JOIN exportImport.dbo.invoices i ON i.id = ii.invoice_id
WHERE i.file_name = N'…'
ORDER BY ii.line_no;
```

**Ручная перевыгрузка накладной** (следующий тик перезапишет строки
в ERP delete+insert):

```sql
UPDATE docs.invoices SET exported_at = NULL WHERE file_name = '…';
```

**Ручная чистка в ERP** (накладная «опустошена» переобработкой —
ноль позиций в ERP не выгружается, старые строки остаются):

```sql
DELETE FROM exportImport.dbo.invoices WHERE file_name = N'…';  -- каскад сносит позиции
```

**Контроль ошибок:** executions `Invoice-007_ERP-export` в n8n — узлы
на error-выходах попадают в «Error sink»; сбойная накладная остаётся
с `exported_at IS NULL` и уходит в повторный тик.
