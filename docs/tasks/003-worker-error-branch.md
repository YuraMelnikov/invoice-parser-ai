# Задача 003. Error-ветка воркера (Invoice-002)

- Дата постановки: 2026-10-07 (backlog), реализация 2026-10-07
- Статус: **выполнена 2026-10-07** (принято владельцем, см. DoD ниже)

## Цель

Сбой на любом шаге обработки накладной в `Invoice-002_Worker` переводит
документ в `status='error'` с читаемым `error_message` вместо молчаливого
падения execution и бесконечного зацикливания через сброс `processing`
диспетчером. Восстанавливает негативный сценарий DoD задачи 001
(битый PDF → `_error/`).

## Диагноз (подтверждён чтением `workflows/Invoice-002_Worker.json`)

1. У узлов `Render PDF`, `Build VLM request`, `Ollama extract`,
   `Parse & validate` стоит `continueErrorOutput`, но error-выходы не
   были никуда подключены — сбойный item испарялся, execution
   завершался без `Set error`.
2. Узлы `Build error` → `Set error` существовали и были связаны между
   собой, но их никто не питал.
3. У Postgres-узлов `Upsert invoice`, `Delete old items`, `Insert items`
   `continueErrorOutput` не было вообще — их сбой ронял execution
   с тем же зацикливанием.

## Реализация

1. Error-выходы четырёх узлов (`Render PDF`, `Build VLM request`,
   `Ollama extract`, `Parse & validate`) подключены ко входу
   `Build error` (n8n допускает несколько соединений в один вход).
2. Postgres-узлам `Upsert invoice`, `Delete old items`, `Insert items`
   добавлен `continueErrorOutput` и error-выход → `Build error`
   (решение владельца 2026-10-07).
3. `Set done` и `Set error` намеренно не тронуты: если недоступен PG
   на финальном апдейте, ретрай остаётся на диспетчере.
4. `Build error` / `Set error` не менялись: `Build error` собирает
   сообщение из любой упавшей ветки (`$input.first().json.error` …) и
   берёт `doc_id` из тела webhook; `Set error` пишет `status='error'`,
   `error_message`, `processed_at` — диспетчер документ больше не
   подбирает.

Проверено скриптом: у 7 узлов два выхода, success-пути не изменились
(цепочка Webhook → … → Set done и Build error → Set error сохранена).

## Scope — что менялось

- `workflows/Invoice-002_Worker.json` — только connections и `settings`
  семи узлов.
- `README.md` — backlog.

## Вне scope

- Логика узлов (JS/SQL) — не менялась.
- Остальные workflow (001/003…007).
- Диспетчер (сброс `processing` остаётся как страховка для непредвиденных
  падений вне error-ветки).

## Что делает владелец (вне scope агента)

1. Реимпорт `workflows/Invoice-002_Worker.json` в n8n: workflow активен —
   деактивировать → импорт (замена) → активировать. Webhook-путь не
   меняется.
2. Негативный тест: положить битый PDF на шару → после тиков диспетчера/
   воркера проверить DoD ниже (агент поможет запросами).

## Definition of Done

- [x] Error-выходы 7 узлов подключены к `Build error`; success-пути
      целы (проверка скриптом 2026-10-07).
- [x] Workflow реимпортирован и активирован (владелец, 2026-10-07).
- [x] Битый PDF: документ получает `status='error'` + читаемый
      `error_message`, файл уносится архивом в `_error/`, повторных
      обработок нет (приёмка владельцем 2026-10-07).
- [x] Позитивный сценарий не сломан: `EPPlus.Interfaces.pdf` пошёл в
      обработку штатно (живой контроль агента 2026-10-07: `processing`
      1,5 мин — активная работа воркера, не зависание).
- [x] В `docs.documents` не остаётся зависших `processing` от сбойных
      файлов (живой контроль 2026-10-07: 4 done, 1 активный processing,
      зависших нет).

**Приёмка владельцем 2026-10-07: «completed».** Задача закрыта.

## Откат

- `git checkout workflows/Invoice-002_Worker.json` + реимпорт.
