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
