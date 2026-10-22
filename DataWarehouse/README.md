# Сховище даних RentalDW

Курсова робота «Надвеликі бази даних», варіант 2 — «Оренда приміщень».

Тут лежать скрипти сховища `RentalDW` (схема «зірка»). Сховище заповнює SSIS-пакет `Rental_ETL.dtsx` з OLTP-бази `Rental`.

## Що потрібно

- Створена й заповнена база `Rental` (див. `Database/README.md` і `DataGeneration/README.md`).
- SSMS, підключення до сервера, наприклад `ANDRUSHA` під `sa`.

## Перше створення сховища

Кожен скрипт: **File → Open → File…** (`Ctrl+O`) → **Execute** (`F5`). Внизу має бути *Query executed successfully*.

| № | Скрипт | Що робить |
|---|---|---|
| 1 | `CREATE_DW_DATABASE.sql` | Створює базу `RentalDW` (якщо її ще немає), recovery `SIMPLE`. |
| 2 | `CREATE_DW_TABLES.sql` | Створює довідник свят, 5 вимірів, 3 таблиці фактів, staging-таблиці SCD і журнали ETL. ⚠️ Спочатку видаляє наявні таблиці разом з даними. |
| 3 | `CREATE_DW_PROCEDURES.sql` | Створює процедури ETL (старт/завершення запуску, SCD1/SCD2, журнали, звірка) і представлення `vw_ETL_RunSummary`. Скрипт можна запускати повторно. |
| 4 | `INSERT_DW_REFERENCE.sql` | Заповнює `Ref_Holiday` державними святами України 2021–2027. Результат — кількість свят по роках (11–12). |

Після цього запускається SSIS-пакет (див. нижче).

## Повторне завантаження «з нуля»

Коли треба очистити сховище і завантажити все заново (наприклад, після невдалого запуску):

1. У SSMS виконайте **`CLEAR_DW_DATA.sql`** — видаляє всі дані вимірів, фактів і журналів ETL, скидає лічильники ключів. Таблиці, процедури та свята залишаються. Результат — таблиця, де всюди 0, крім `Ref_Holiday`.
2. Видаліть файл контрольної точки **`C:\Users\Public\Rental_ETL.chk`**, якщо він існує. Він з'являється лише після невдалого запуску; без видалення пакет продовжить з місця падіння, а не почне спочатку.
3. Переконайтеся, що в `Project.params` (Solution Explorer → `Project.params`) `LoadMode` = `FULL`.
4. У Visual Studio відкрийте `Rental_ETL.dtsx` і натисніть **Start**.

Якщо змінювалась структура таблиць (`CREATE_DW_TABLES.sql`), то замість кроку 1 виконайте скрипти 2 → 3 → 4 з розділу вище.

## Режими завантаження

- `FULL` — повне завантаження всіх даних.
- `INCREMENTAL` — лише нові рахунки й платежі (після останніх `LastInvoiceID` / `LastPaymentID` в `ETL_Audit`) та перезавантаження неоплачених рахунків. Якщо успішного FULL-запуску ще не було, пакет сам перемикається на `FULL`.

## Перевірка інкрементального завантаження

1. Виконайте повний запуск (`LoadMode` = `FULL`), він має завершитися успішно.
2. У SSMS виконайте `DataGeneration/07_INCREMENTAL_TEST_DATA.sql` — він вносить у базу `Rental` нові та змінені дані й показує, скільки рядків змінено на кожному кроці.
3. У `Project.params` встановіть `LoadMode` = `INCREMENTAL` і запустіть пакет.
4. Що має статися:

| Зміна в OLTP | Результат у сховищі |
|---|---|
| Нові телефони 10 орендарів | `Dim_Tenant`: 10 рядків оновлено (SCD1), нових ключів немає |
| Ціна 20 приміщень +10 % | `Dim_Premises`: 20 старих версій закрито (`IsCurrent = 0`, `ValidTo`), 20 нових версій додано (SCD2) |
| Розірвано 5 договорів | `Dim_Contract`: 5 рядків оновлено (SCD1: `TerminationDate`, тривалість) |
| Новий орендар і договір | По 1 новому рядку в `Dim_Tenant` і `Dim_Contract` |
| 300 погашених боргів | `Fact_Payment`: +300; ці рахунки перезавантажено у `Fact_Invoice` зі статусом «Оплачено» |
| Рахунки за наступний місяць | Нові рядки у `Fact_Invoice` |

Кількість рядків у фактах після запуску має збігатися з OLTP (`usp_ETL_Reconcile`, колонки `DiffInvoices` / `DiffPayments` = 0).

```sql
USE RentalDW;
SELECT TOP (2) * FROM dbo.vw_ETL_RunSummary ORDER BY RunID DESC;
SELECT * FROM dbo.ETL_RowCount WHERE RunID = (SELECT MAX(RunID) FROM dbo.ETL_Audit);
SELECT PremisesID, MonthlyPrice, ValidFrom, ValidTo, IsCurrent
FROM dbo.Dim_Premises WHERE PremisesID BETWEEN 1 AND 3 ORDER BY PremisesID, ValidFrom;   -- історія SCD2
```

## Перевірка після запуску

Усі звіти контролю якості ETL (журнал запусків, оброблені рядки, помилки, відбраковані рядки, звірка з OLTP, історія SCD2) зібрано у **`ETL_REPORTS.sql`**. Найважливіші запити:

```sql
USE RentalDW;
SELECT * FROM dbo.vw_ETL_RunSummary ORDER BY RunID DESC;        -- запуски, режим, статус, тривалість
SELECT * FROM dbo.ETL_RowCount WHERE RunID = (SELECT MAX(RunID) FROM dbo.ETL_Audit);
SELECT TOP (50) * FROM dbo.ETL_ErrorLog ORDER BY ID DESC;        -- помилки пакета (обробник OnError)
SELECT TOP (50) * FROM dbo.ETL_ErrorRow ORDER BY ID DESC;        -- відбраковані рядки даних
```
