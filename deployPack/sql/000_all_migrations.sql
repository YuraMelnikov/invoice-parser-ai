-- ============================================================
-- deployPack: ЕДИНЫЙ файл миграций схемы docs.*
-- Содержит миграции 001-004 в порядке наката:
--   001_schema.sql       - базовая схема (documents, invoices, invoice_items)
--   002_archived_at.sql  - пайплайн dispatcher/worker/archive (ADR-0002)
--   003_embeddings.sql   - линковка позиций с ERP (ADR-0004)
--   004_erp_export.sql   - экспорт в ERP MS SQL (ADR-0005)
-- Идемпотентно: повторный накат безопасен.
-- Накат: psql -U <POSTGRES_USER> -d <POSTGRES_DB> -f 000_all_migrations.sql
-- ============================================================


-- ============================================================
-- Шаг 1. Схема Postgres для загрузки приходных накладных
-- База: invoices (создаётся compose'ом), схема: docs
-- ============================================================

CREATE SCHEMA IF NOT EXISTS docs;

-- ------------------------------------------------------------
-- Очередь документов: одна строка = один PDF-файл на шаре.
-- Здесь же лог, как завершилась обработка файла.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS docs.documents (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    file_name     text NOT NULL UNIQUE,        -- имя файла, например 'scan_001.pdf'
    file_path     text NOT NULL,               -- путь относительно /data/docs
    file_size     bigint,                      -- размер файла
    status        text NOT NULL DEFAULT 'new'
                  CHECK (status IN ('new', 'processing', 'done', 'error')),
    status_changed_at timestamptz NOT NULL DEFAULT now(),  -- метка последней смены status
                                                           -- (диспетчер сбрасывает зависшие processing)
    error_message text,                        -- ошибка, если произошла
    created_at    timestamptz NOT NULL DEFAULT now(),
    processed_at  timestamptz                  -- когда файл дошёл до статуса done/error
);

CREATE INDEX IF NOT EXISTS documents_status_idx ON docs.documents (status);

-- ------------------------------------------------------------
-- Извлечённые из накладной данные.
-- Шапка (supplier_*, doc_*) не хранится — решение владельца 2026-10-05
-- нужны только позиции. Полный ответ LLM — в raw_json.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS docs.invoices (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    file_name     text NOT NULL UNIQUE
                  REFERENCES docs.documents (file_name) ON UPDATE CASCADE,
    raw_json      jsonb,                       -- полный структурированный ответ LLM
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------
-- Табличная часть накладной: одна строка = одна позиция товара.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS docs.invoice_items (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id bigint NOT NULL
               REFERENCES docs.invoices (id) ON DELETE CASCADE,
    line_no    integer NOT NULL,               -- порядковый номер строки в документе
    item_name  text NOT NULL,                  -- наименование товара
    unit       text,                           -- единица измерения (шт, кг, упак...)
    quantity   numeric(14, 3),                 -- количество
    price      numeric(14, 2),                 -- цена за единицу
    UNIQUE (invoice_id, line_no)
);

-- ============================================================
-- Примечания:
--  1. Схема накатывается автоматически: compose монтирует ./sql
--     в /docker-entrypoint-initdb.d (только при ПЕРВОМ старте
--     пустого postgres_storage; для перенаката — psql -f).
-- ============================================================

-- ============================================================
-- Шаг 2. Пайплайн dispatcher → worker → archive (задача 001, ADR-0002)
-- Идемпотентно: повторный накат безопасен.
-- ============================================================

-- Отметка «файл выведен из входной папки» (в _archive или _error).
-- NULL — файл ещё на месте; workflow archive берёт только NULL.
ALTER TABLE docs.documents
    ADD COLUMN IF NOT EXISTS archived_at timestamptz;

-- mtime файла на шаре на момент последнего наблюдения диспетчером.
-- Диспетчер обновляет каждый тик (пока status='new'); в батч на обработку
-- попадают только файлы, чей mtime старше 3 минут — защита от захвата
-- файла, который ещё копируется на шару (ADR-0002).
ALTER TABLE docs.documents
    ADD COLUMN IF NOT EXISTS file_mtime timestamptz;

-- Быстрый поиск необработанных архиватором записей.
CREATE INDEX IF NOT EXISTS documents_archived_idx
    ON docs.documents (archived_at) WHERE archived_at IS NULL;


-- ============================================================
-- Шаг 3. Линковка позиций со справочником ERP (задача 002)
-- Идемпотентно: повторный накат безопасен.
-- ============================================================

-- Кэш «вектор позиции записан в Qdrant».
-- Ключ (file_name, line_no), а НЕ item_id: worker при переобработке файла
-- делает delete+insert, item_id меняются, а пара (file_name, line_no)
-- стабильна — перевекторизация не нужна, сирот в коллекции нет
-- (решение владельца 2026-10-07, задача 002 п.6).
CREATE TABLE IF NOT EXISTS docs.item_embeddings (
    file_name  text NOT NULL,
    line_no    integer NOT NULL,
    model      text NOT NULL,              -- напр. 'bge-m3'
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (file_name, line_no)
);

-- Результат линковки — прямо в строке позиции (решение владельца 2026-10-07):
ALTER TABLE docs.invoice_items
    ADD COLUMN IF NOT EXISTS sku_code text;        -- код номенклатуры ERP; NULL = не слинковано

ALTER TABLE docs.invoice_items
    ADD COLUMN IF NOT EXISTS link_score numeric;   -- score top-1 от матчера (диагностика);
                                                   -- NULL = матчер строку ещё не видел

ALTER TABLE docs.invoice_items
    ADD COLUMN IF NOT EXISTS link_processed boolean NOT NULL DEFAULT false;
                                                   -- матчер отработал строку (независимо от результата)

-- Как слинковано: 'article' (детерминированное совпадение артикула),
-- 'vector' (семантический top-1, score >= T1), NULL — не слинковано.
-- Гибридный матчер: bge-m3 не различает артикулы, отличающиеся одним
-- знаком (калибровка 2026-10-07: score 0.92 у «чужой» модели), поэтому
-- при наличии артикула с обеих сторон решает строковое сравнение (ADR-0004).
ALTER TABLE docs.invoice_items
    ADD COLUMN IF NOT EXISTS link_method text;

-- Очередь матчера: строки, которые он ещё не видел.
CREATE INDEX IF NOT EXISTS invoice_items_link_queue_idx
    ON docs.invoice_items (link_processed) WHERE link_processed = false;

-- ============================================================
-- Примечания:
--  1. Кэша справочника SKU нет намеренно: каталог ~365 строк,
--     Invoice-005 делает полный рефреш коллекции sku_catalog каждый тик
--     (решение владельца 2026-10-07, п.3).
--  2. Неслинкованное смотрим так:
--     SELECT * FROM docs.invoice_items
--     WHERE link_processed = true AND sku_code IS NULL;
-- ============================================================


-- ============================================================
-- Шаг 4. Экспорт накладных в ERP MS SQL (задача 004, ADR-0005)
-- Идемпотентно: повторный накат безопасен.
-- ============================================================

-- Метка «накладная выгружена в ERP». NULL = требует выгрузки.
-- Проставляет Invoice-007_ERP-export после успешной записи в MS SQL.
ALTER TABLE docs.invoices
    ADD COLUMN IF NOT EXISTS exported_at timestamptz;

-- Очередь экспорта.
CREATE INDEX IF NOT EXISTS invoices_export_queue_idx
    ON docs.invoices (exported_at) WHERE exported_at IS NULL;

-- Worker при переобработке файла делает delete+insert ТОЛЬКО позиций
-- (docs.invoice_items); шапка docs.invoices и её exported_at
-- сохраняются. Чтобы перевыгрузка в ERP случилась сама, любое
-- изменение состава позиций сбрасывает exported_at в NULL.
-- Срабатывания матчера (UPDATE link_*) метку не трогают — триггер
-- только на INSERT/DELETE.
CREATE OR REPLACE FUNCTION docs.reset_exported_at() RETURNS trigger AS $$
BEGIN
    UPDATE docs.invoices
       SET exported_at = NULL
     WHERE id = COALESCE(NEW.invoice_id, OLD.invoice_id)
       AND exported_at IS NOT NULL;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS invoice_items_reset_export ON docs.invoice_items;
CREATE TRIGGER invoice_items_reset_export
    AFTER INSERT OR DELETE ON docs.invoice_items
    FOR EACH ROW EXECUTE FUNCTION docs.reset_exported_at();

-- ============================================================
-- Примечания:
--  1. Очередь выгрузки (как видит её Invoice-007):
--       SELECT i.id, i.file_name
--       FROM docs.invoices i
--       WHERE i.exported_at IS NULL
--         AND EXISTS (SELECT 1 FROM docs.invoice_items ii
--                      WHERE ii.invoice_id = i.id
--                        AND ii.link_processed = true)
--         AND NOT EXISTS (SELECT 1 FROM docs.invoice_items ii
--                          WHERE ii.invoice_id = i.id
--                            AND ii.link_processed IS NOT TRUE);
--  2. Накладная с нулём позиций в ERP не выгружается.
-- ============================================================
