# Задача 001. Пайплайн обработки накладных: dispatcher → worker → archive

- Дата постановки: 2026-10-06
- Статус: в эксплуатации с 2026-10-07. Workflow импортированы и активны,
  продовые правки владельца (батч 1, таймаут 30 мин, dpi 400) зафиксированы
  в ADR-0003 и синхронизированы в `workflows/`. E2E happy path пройден
  (4 эталона done + `_archive/`). Данные в БД сверены с эталонами — 4/4
  (2026-10-07). Открыто: error-ветка воркера не подключена
  (негативный сценарий не работает).

## Цель

Автоматическая обработка приходных накладных с шары: файлы регистрируются
в очередь (dispatcher), извлекаются позиции vision-моделью (worker),
успешно обработанные уезжают в `_archive` (archive). Результат — строки
в `docs.invoices` + `docs.invoice_items`.

## Scope — что можно менять

- `workflows/` (новая папка): `dispatcher.json`, `worker.json`, `archive.json`
  — финальные версии workflow для импорта в n8n; исходники черновиков — в
  `tmp/dispatcher.json`, `tmp/archive.json`.
- `sql/002_archived_at.sql` — новая миграция (`archived_at`,
  `ADD COLUMN IF NOT EXISTS`).
- `docs/decisions/` — ADR по решениям этой задачи (стабильность файла,
  политика error-файлов, коллизии в архиве).
- `README.md` — decision log, статус.

## Вне scope

- `shared/pdf-render/` (сервис работает, проверен 2026-10-06).
- `tests/fixtures/*` (эталоны — только владелец).
- n8n-креды и `.env` (настраивает владелец в UI).

## Открытые вопросы — РЕШЕНЫ владельцем 2026-10-06 («да» на все три)

1. Стабильность файла: в батч только файлы с mtime старше 3 минут. ✅
2. Error-файлы: archive переносит их в `_error/`. ✅
3. Коллизия имён в `_archive`: префикс `YYYYMMDD-HHMMSS_`. ✅

Решения зафиксированы в ADR-0002.

## Реализация (что сделано агентом)

- `sql/002_archived_at.sql` — колонки `archived_at`, `file_mtime`, частичный
  индекс; идемпотентна.
- `workflows/dispatcher.json` — upsert с file_mtime, батч со стабильностью,
  claim + fire-and-forget dispatch на webhook воркера.
- `workflows/worker.json` — webhook (Respond Immediately) → pdf-render →
  qwen3-vl:8b (JSON-схема, только items) → валидация → upsert invoices →
  delete+insert items → done; все ошибки → error + error_message.
- `workflows/archive.json` — done → `_archive/`, error → `_error/`,
  идемпотентный перенос, префикс при коллизии, тик 5 мин.
- `docs/decisions/0002-pipeline-dispatcher-worker-archive.md`.

## Что делает владелец (вне scope агента)

1. Перенакат миграции: `docker compose exec postgres psql -U $POSTGRES_USER -d $POSTGRES_DB -f /docker-entrypoint-initdb.d/002_archived_at.sql`.
2. Импорт трёх workflow в n8n, привязка креды Postgres, активация всех трёх.
3. Проверка, что webhook воркера — Respond Immediately (в файле выставлено,
   при импорте не слетает, но проверить).

## Definition of Done

- [ ] `sql/002_archived_at.sql` идемпотентна: повторный `psql -f` — без ошибок.
- [ ] Три workflow импортированы в n8n, активны, креды привязаны.
- [ ] Webhook воркера отвечает немедленно (Respond Immediately).
- [ ] E2E: PDF кладём на шару → в течение 1 тика диспетчера строка в
  `docs.documents` (status=new) → после воркера `done`, позиции в
  `docs.invoice_items` → файл в `_archive/`, `archived_at` заполнено.
- [ ] Повторный прогон того же файла не плодит дубли (проверка UNIQUE и
  отсутствия дублей в `invoice_items`).
- [ ] Битый PDF (не накладная) → status=error, `error_message` заполнено,
  файл не теряется.
- [x] Решения по открытым вопросам зафиксированы: ADR-0002 + decision log.

## Откат

- Деактивировать workflow в n8n; `workflows/` и миграцию удалить из git
  (`git checkout`/`git clean`), колонку `archived_at` можно оставить —
  она ничему не мешает.
