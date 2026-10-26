# ADR-0005. Экспорт накладных в ERP (MS SQL): инкремент по exported_at, delete+insert по file_name

- Дата: 2026-10-07
- Статус: принято

## Контекст

Задача 004: распознанные накладные (`docs.invoices`, `docs.invoice_items`)
должны автоматически попадать в БД ERP на MS SQL — туда, где уже живёт
справочник номенклатуры `exportImport.dbo.CurrentOrder` (задача 002).
Пайплайн выше по потоку переобрабатывает файлы: worker делает
delete+insert **только позиций** (`docs.invoice_items`), шапка
`docs.invoices` и её `id` сохраняются.

## Решение (все пункты — решения владельца 2026-10-07)

1. **Целевые таблицы — `exportImport.dbo.invoices` и
   `exportImport.dbo.invoice_items`.** Поля `invoice_items` повторяют
   выборку `SELECT id, invoice_id, line_no, item_name, unit, quantity,
   price, sku_code FROM docs.invoice_items`; PK — `id` из Postgres
   (bigint identity на стороне PG, в MS SQL — просто bigint).
   Таблицы создаёт сам workflow `Invoice-007_ERP-export` идемпотентным
   DDL (`IF OBJECT_ID … IS NULL`) — права у кредов «Microsoft SQL
   account» подтверждены владельцем.
2. **Что выгружаем:** накладные, у которых есть позиции и ВСЕ позиции
   отработаны матчером (`link_processed = true`). Неслинкованные позиции
   уходят в ERP с `sku_code = NULL` (видны там же запросом).
3. **Инкремент:** колонка `docs.invoices.exported_at` (миграция
   `sql/004_erp_export.sql`), NULL = требует выгрузки. Очередь —
   частичный индекс. Батч 10 накладных на тик, тик 5 минут.
4. **Переобработка:** в ERP — delete+insert по `file_name` в одной
   транзакции (`SET XACT_ABORT ON; BEGIN TRAN; … COMMIT;`); каскад
   `ON DELETE CASCADE` сносит старые позиции. Устойчиво к смене `id`
   шапки. В PG — триггер `invoice_items_reset_export` (AFTER
   INSERT/DELETE на `docs.invoice_items`) сбрасывает `exported_at` в
   NULL: без него delete+insert позиций воркером не трогал бы шапку, и
   перевыгрузки не случилось бы. UPDATE от матчера (`link_*`) триггер
   не задевает.
5. **Порядок метки:** `exported_at = now()` ставится только после
   успешной записи в MS SQL. Сбой записи → метка не ставится → повтор
   на следующем тике безопасен (delete+insert идемпотентен).

## Последствия

- Накладная с нулём позиций в ERP не выгружается (очередь требует
  хотя бы одной позиции). Если переобработка «опустошила» накладную,
  старые строки в ERP остаются — ручная чистка (RUNBOOK §11).
- Окно гонки: между записью в MS SQL и простановкой `exported_at`
  возможен дубль записи при падении — закрыт транзакционным
  delete+insert (повтор даёт тот же результат).
- Тик 5 мин даёт потолок ~120 накладных/час при батче 10 — с запасом
  выше складского потока.
- Схема ERP-таблиц заморожена постановкой; новые поля (например,
  `link_score`) в ERP не идут — при необходимости новая ADR.

## Проверено

- Миграция `sql/004_erp_export.sql` накатана на продовый Postgres,
  идемпотентна (двойной прогон 2026-10-07).
- `workflows/Invoice-007_ERP-export.json` — валидный JSON; креды
  Postgres зашиты (id `uSXpwajUhahtQd3N`), MSSQL — привязка при импорте
  (как в Invoice-005).
- Живая сверка PG ↔ ERP — после импорта и активации владельцем
  (DoD задачи 004).
