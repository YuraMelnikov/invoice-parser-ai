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
