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