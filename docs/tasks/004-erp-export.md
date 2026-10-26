# Задача 004. Экспорт накладных из Postgres в ERP (MS SQL)

- Дата постановки: 2026-10-07
- Статус: **выполнена 2026-10-07** (принято владельцем, см. DoD ниже)

## Цель

Распознанные накладные и их позиции из `docs.invoices` / `docs.invoice_items`
(Postgres) автоматически попадают в БД ERP (MS SQL): n8n-workflow по
расписанию переносит данные в таблицы `invoices` и `invoice_items` на
стороне ERP.

## Решения владельца (2026-10-07)

1. Таблицы — в `exportImport.dbo` (та же база, что справочник
   `CurrentOrder`): `invoices (id, file_name)` и `invoice_items` с полями
   под выборку `SELECT id, invoice_id, line_no, item_name, unit, quantity,
   price, sku_code FROM docs.invoice_items`.
2. Выгружать накладные, позиции которых отработаны матчером:
   `link_processed = true`. Неслинкованные позиции уходят с
   `sku_code = NULL`.
3. Стратегия — инкрементальная (только новые/изменённые).
4. При переобработке файла — delete+insert: строки накладной в ERP
   заменяются.
5. Тик workflow — каждые 5 минут.
6. Права у кредов «Microsoft SQL account» есть (CREATE TABLE / INSERT /
   DELETE) — таблицы создаёт сам workflow идемпотентным DDL.

## Реализация

### Шаг 1. Миграция `sql/004_erp_export.sql` (идемпотентна)

- `docs.invoices.exported_at timestamptz` — NULL = требует выгрузки в ERP;
  проставляет workflow после успешной записи в MS SQL.
- Частичный индекс очереди `invoices_export_queue_idx`.
- Триггер `invoice_items_reset_export` (AFTER INSERT/DELETE на
  `docs.invoice_items`) сбрасывает `exported_at` в NULL: worker при
  переобработке файла делает delete+insert только позиций (шапка и её
  метка сохраняются), поэтому без триггера перевыгрузка бы не случилась.
  Срабатывания матчера (UPDATE `link_*`) метку не трогают.

### Шаг 2. Workflow `workflows/Invoice-007_ERP-export.json`

Тик 5 мин. Узлы:

1. **Ensure ERP tables** (MSSQL) — идемпотентный DDL `IF OBJECT_ID … IS
   NULL CREATE TABLE` для обеих таблиц в `exportImport.dbo`.
2. **Get invoices to export** (Postgres) — кандидаты: `exported_at IS
   NULL`, есть позиции, ВСЕ позиции `link_processed = true`; батч 10;
   позиции забираются тем же запросом (`jsonb_agg`).
3. **Build T-SQL** (Code) — на каждую накладную один транзакционный
   батч: `BEGIN TRAN` → `DELETE … WHERE file_name = …` (каскад сносит
   старые позиции; устойчиво к смене `id` при переобработке) → `INSERT`
   шапки и позиций → `COMMIT`.
4. **Write to ERP** (MSSQL) — выполняет батч по каждой накладной.
5. **Mark exported** (Postgres) — `exported_at = now()` только после
   успешной записи (error-выход узла 4 сюда не попадает → накладная
   уйдёт в повторный тик, delete+insert делает повтор безопасным).

Идемпотентность: повтор тика по уже выгруженному не берёт строки
(очередь по `exported_at IS NULL`); повторное выполнение того же T-SQL
батча даёт тот же результат (delete+insert в транзакции).

Креды: Postgres — `uSXpwajUhahtQd3N` (зашиты); MSSQL — «Microsoft SQL
account» (привязать при импорте, как в Invoice-005).

### Ограничения (приняты)

- Накладная с нулём позиций в ERP не выгружается (нечего сверять).
- Если переобработка «опустошила» накладную (0 позиций), старые строки
  в ERP остаются — ручная чистка запросом из RUNBOOK §11.

## Scope — что менялось

- `sql/004_erp_export.sql` (новая миграция).
- `workflows/Invoice-007_ERP-export.json` (новый файл).
- `docs/decisions/0005-erp-export-mssql.md` — ADR.
- `README.md` — decision log.
- `RUNBOOK.md` — §11 (проверки, SQL контроля).

## Вне scope

- `workflows/Invoice-001…006*` и продовые workflow в n8n.
- `tests/fixtures/*.expected.json` — только владелец.
- Существующие данные и схема ERP, кроме двух новых таблиц
  (`exportImport.dbo.CurrentOrder` — только чтение, как раньше).
- Error-ветка воркера (backlog-задача 003).

## Что делает владелец (вне scope агента)

1. Импортировать `workflows/Invoice-007_ERP-export.json` в n8n, привязать
   MSSQL-узлы («Ensure ERP tables», «Write to ERP») к кредам «Microsoft
   SQL account» (Postgres-креды зашиты).
2. Активировать workflow.
3. После первого тика — проверка по DoD ниже (агент поможет запросами).

## Definition of Done

- [x] Миграция 004 идемпотентна: повторный `psql -f` — без ошибок.
- [x] Workflow JSON валиден, креды Postgres зашиты, MSSQL — помечены
      к привязке (как в Invoice-005).
- [x] Workflow импортирован, активен, креды MSSQL привязаны (владелец,
      2026-10-07).
- [x] После тика в ERP появились таблицы `exportImport.dbo.invoices` /
      `invoice_items` и строки, идентичные PG (владелец, 2026-10-07).
      Живой контроль со стороны PG: `exported_at` проставлен у
      test_01 (21/21 позиций), test_03, test_04; test_02 (0 позиций)
      корректно не выгружается — задокументированное ограничение.
- [x] Идемпотентность: повторный тик не создаёт дублей — очередь по
      `exported_at IS NULL`, delete+insert в транзакции (приёмка
      владельцем 2026-10-07).
- [x] Переобработка накладной в PG заменяет её строки в ERP:
      триггер `invoice_items_reset_export` сбрасывает `exported_at`
      (проверен агентом на INSERT и DELETE в транзакции с откатом),
      дальше delete+insert по `file_name` (приёмка владельцем).
- [x] Стратегия экспорта зафиксирована: ADR-0005 + decision log.

**Приёмка владельцем 2026-10-07: «super solution, completed».**
Задача закрыта.

## Откат

- Деактивировать workflow в n8n; файл workflow и миграцию убрать из git.
  Таблицы в ERP можно оставить (ни на что не влияют) или удалить руками
  — по решению владельца. Колонка `exported_at` и триггер в PG безвредны.
