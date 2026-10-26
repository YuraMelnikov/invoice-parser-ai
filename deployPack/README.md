# deployPack — пакет развёртывания «Оператор склада» с нуля

Полный пакет для поднятия решения на новом ПК: стек Docker (postgres, n8n,
ollama, qdrant, pgadmin, pdf-render), единый файл SQL-миграций,
n8n-workflow пайплайна, sidecar рендера PDF и эталоны для eval-проверки.

Детали эксплуатации — в `RUNBOOK.md` (идёт в пакете).

## Состав пакета

```
docker-compose.yml        # стек целиком (профили: cpu / gpu-nvidia / gpu-amd)
.env.example              # шаблон переменных — скопировать в .env и заполнить
RUNBOOK.md                # эксплуатация, проверки, траблшутинг
sql/
  000_all_migrations.sql  # ВСЕ миграции схемы docs.* одним файлом (идемпотентно)
shared/
  pdf-render/             # sidecar рендера PDF→PNG (app.py + Dockerfile)
  prompts/                # системный промт экстракции (общий с продом)
workflows/                # 7 n8n-workflow: Invoice-001…007
tests/                    # eval-скрипт + эталонные PDF и expected JSON
```

## Шаг 0. Требования к новому ПК

- Docker с compose-плагином (`docker compose version` без ошибок);
  на Windows — Docker Desktop.
- Доступ к SMB-шаре с накладными (в compose зашита
  `//192.168.1.30/m/Приходные накладные/AI` — при другом адресе
  поправить `volumes.docs_ai.driver_opts.device` в `docker-compose.yml`).
- Для GPU-профилей: NVIDIA (nvidia-container-toolkit) или AMD ROCm.
- Доступ к ERP MS SQL (для workflow Invoice-005/007) — хост, база
  `exportImport`, логин с правами CREATE TABLE / INSERT / DELETE.

## Шаг 1. Переменные окружения

```bash
cp .env.example .env   # затем заполнить значения
```

Обязательно заполнить: `POSTGRES_*`, `N8N_ENCRYPTION_KEY`,
`N8N_USER_MANAGEMENT_JWT_SECRET`, `SMB_USER`, `SMB_PASS`.

## Шаг 2. Запуск стека

```bash
# CPU:
docker compose --profile cpu up -d

# NVIDIA GPU:
docker compose --profile gpu-nvidia up -d

# AMD GPU:
docker compose --profile gpu-amd up -d
```

Init-контейнер `ollama-pull-models` сам докачивает модели
(`qwen3-vl:8b-instruct-q8_0`, `qwen3:8b`, `bge-m3`) и завершается —
прогресс: `docker logs -f ollama-pull-models`. Закачка ~10 ГБ, на
слабом канале — долго, это нормально.

## Шаг 3. Миграции БД

Схема `docs.*` накатывается АВТОМАТИЧЕСКИ при первом старте на пустом
volume `postgres_storage`: compose монтирует `./sql` в
`/docker-entrypoint-initdb.d`, и Postgres выполнит
`000_all_migrations.sql` целиком.

Если автонакат не сработал (например, volume уже существовал) — перенакат
вручную, файл идемпотентен:

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -f /docker-entrypoint-initdb.d/000_all_migrations.sql
```

Проверка: `docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dt docs.*"'`
→ 4 таблицы: `documents`, `invoices`, `invoice_items`, `item_embeddings`.

## Шаг 4. Импорт workflow в n8n

1. Открыть n8n: http://localhost:5678 (при первом входе создать
   владельца-админа).
2. Создать креденшелы (Settings → Credentials):
   - **Postgres** — host `postgres`, port 5432, DB/логин/пароль из `.env`
     (`POSTGRES_DB`/`POSTGRES_USER`/`POSTGRES_PASSWORD`).
   - **Microsoft SQL Server** — подключение к ERP MS SQL (база `exportImport`).
3. Импортировать все 7 файлов из `workflows/` (меню ⋯ → Import from File).
4. В каждом workflow перевыбрать креденшелы в узлах Postgres / Microsoft SQL
   (ID креденшелов из исходной установки на новом ПК не существуют),
   сохранить.
5. Активировать все workflow (тоггл Active). У воркера проверить: webhook
   настроен на Respond Immediately.

## Шаг 5. Проверка после старта

```bash
docker compose ps                                   # все (healthy)/running
curl http://localhost:8000/health                   # pdf-render: {"status":"ok"}
docker exec ollama ollama list                      # 3 модели на месте
```

Далее — E2E-проверка пайплайна по `RUNBOOK.md` §7 (положить тестовый PDF
на шару, пройти шаги регистрация → обработка → архивация → негатив →
идемпотентность). Учитывать: первый рендер ~90 с (холодная модель);
тайминги тиков — dispatcher 10 мин, worker до ~10 мин/док при 400 dpi,
archive 5 мин.

## Шаг 6. Eval качества (опционально)

```bash
python tests/run_eval.py   # сверка распознавания эталонов с expected JSON
```

Эталоны `tests/fixtures/*.expected.json` — источник истины, не править.

## Что НЕ входит в пакет

- Данные: очередь документов, распознанные накладные, вектора Qdrant —
  создаются заново на новом хосте.
- Креденшелы n8n и ключи шифрования — создаются на месте (шаг 4).
- Справочник SKU из ERP — подтянется сам первым тиком `Invoice-005_SKU-sync`.
