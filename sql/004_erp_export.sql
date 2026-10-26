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
