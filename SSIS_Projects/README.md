# ETL-процеси (SSIS)

Курсова робота «Надвеликі бази даних», варіант 2 — «Оренда приміщень».

Проєкт Integration Services `Rental_SSIS` переносить дані з OLTP-бази `Rental` у сховище `RentalDW` (схема «зірка»: 5 вимірів, 3 таблиці фактів, таблиці аудиту).

## Склад папки

| Шлях | Що це |
|---|---|
| `Rental_SSIS.sln`, `Rental_SSIS/Rental_SSIS.dtproj` | Рішення та проєкт Visual Studio (SSIS, TargetServerVersion SQL Server 2025) |
| `Rental_SSIS/ANDRUSHA.Rental.sa.conmgr` | Підключення до джерела `Rental` (OLE DB, SQLOLEDB, як у Lab1) |
| `Rental_SSIS/ANDRUSHA.RentalDW.sa.conmgr` | Підключення до сховища `RentalDW` |
| `Rental_SSIS/Project.params` | Параметр проєкту `LoadMode`: `FULL` або `INCREMENTAL` |
| `Rental_SSIS/Rental_ETL.dtsx` | ETL-пакет |
| `ScriptTask_QualityCheck.cs` | Код Script Task «Оцінка якості ETL» |
| `generator/` | Python-скрипти, якими згенеровано XML пакета (див. нижче) |

## Як запустити

1. Створіть сховище: `DataWarehouse/README.md`, скрипти 1–4.
2. Відкрийте `Rental_SSIS.sln` у Visual Studio 2022 з розширенням SQL Server Integration Services Projects.
3. У Solution Explorer відкрийте `Project.params` і виберіть режим `LoadMode`.
4. Відкрийте `Rental_ETL.dtsx` і натисніть **Start**. Хід виконання видно на вкладці **Progress**, а результат — у таблицях аудиту (`DataWarehouse/ETL_REPORTS.sql`).

## Структура пакета `Rental_ETL.dtsx`

```
Підготовка (Sequence)
 ├─ Початок ETL ............ Execute SQL: usp_ETL_Start — RunID, фактичний режим, watermark-и
 └─ Підготовка фактів ...... Execute SQL: usp_ETL_PrepareFacts — очищення (FULL) або видалення змінених рахунків (INCREMENTAL)
Виміри (Sequence)
 ├─ Dim_Date → Dim_InvoiceStatus → Dim_Tenant → SCD1 орендарі
 ├─ Dim_Premises → SCD2 приміщення → Dim_Contract → SCD1 договори
 └─ Журнал вимірів ......... кількість нових/змінених рядків в ETL_RowCount
Факти (Sequence)
 ├─ Список років ........... Execute SQL → змінна-об'єкт User::YearList
 ├─ Рахунки по роках ....... For Each Loop (ADO enumerator): Data Flow Fact_Invoice + журнал року
 ├─ Fact_Payment → Fact_Occupancy
 ├─ Ключі SCD2 у фактах .... підстановка версії приміщення, чинної на дату факту
 └─ Журнал фактів
Звірка ..................... Execute SQL: usp_ETL_Reconcile — розбіжності джерела і сховища
Оцінка якості ETL .......... Script Task (C#): статус запуску Success / Warning / Failed
Завершення ETL ............. Execute SQL: usp_ETL_End — статус, час, нові watermark-и
Event Handler OnError ...... Execute SQL: usp_ETL_LogError — запис у ETL_ErrorLog, запуск = Failed
```

## Трансформації в Data Flow

| Вимога ТЗ | Компонент SSIS | Де використано |
|---|---|---|
| Очищення даних | Derived Column «Очищення» (`TRIM`, заміна NULL email), Sort з видаленням дублікатів «Унікальні дати», Conditional Split «Перевірка рахунку/платежу» (некоректні суми → відбраковка) | Dim_Tenant, Dim_Date, Fact_Invoice, Fact_Payment |
| Конвертація даних | Data Conversion «Конвертація типів» (varchar → nvarchar), приведення типів у Derived Column | Dim_Tenant, Fact_Occupancy |
| Похідні колонки | Derived Column: атрибути календаря, категорії поверху/площі/групи типів, тривалість і категорія договору, борг, своєчасність оплати, завантаженість | усі потоки |
| Lookup | Свята, наявні рядки вимірів, сурогатні ключі вимірів для фактів | усі потоки |
| Агрегація | Aggregate «Сплачено по рахунку» (SUM, MAX), «Підсумок за місяць» (GROUP BY, SUM) | Fact_Invoice, Fact_Occupancy |
| Умовний розподіл | Conditional Split: нові / змінені рядки (SCD), коректні / некоректні факти | Dim_Tenant, Dim_Premises, Dim_Contract, факти |
| Об'єднання | Union All «Відбраковані рядки», Merge Join «Рахунки + платежі» | Fact_Invoice, Fact_Payment |
| Підрахунок рядків | Row Count у змінні `User::Rows*` → журнал `ETL_RowCount` | усі потоки |

## Повне та інкрементальне завантаження

- **FULL** — факти очищаються, виміри доповнюються новими рядками та оновлюються (SCD).
- **INCREMENTAL** — завантажуються лише нові й змінені дані:
  - `Fact_Payment` — платежі з `PaymentID` більшим за watermark попереднього успішного запуску;
  - `Fact_Invoice` — нові рахунки та рахунки, у яких змінився статус або з'явилися нові платежі. `usp_ETL_PrepareFacts` спершу видаляє їх зі сховища, а пакет читає з OLTP всі рахунки, яких немає у `Fact_Invoice`;
  - `Fact_Occupancy` — знімок, щоразу перебудовується повністю;
  - виміри — нові рядки через Lookup (No Match Output), змінені — через staging-таблиці та процедури SCD.
- Якщо успішного запуску ще не було, `INCREMENTAL` автоматично стає `FULL` (видно в `ETL_Audit.RequestedMode` / `LoadMode`).
- Перевірка інкрементального режиму: `DataGeneration/07_INCREMENTAL_TEST_DATA.sql` + `DataWarehouse/README.md`.

## SCD

| Вимір | Тип | Як працює |
|---|---|---|
| `Dim_Tenant` | SCD1 | Змінені рядки потрапляють у `Stage_Tenant`, процедура `usp_ETL_ApplyTenantSCD1` перезаписує атрибути |
| `Dim_Contract` | SCD1 | `Stage_Contract` → `usp_ETL_ApplyContractSCD1` (дата розірвання, тривалість) |
| `Dim_Premises` | SCD2 | Зміна ціни, типу, площі чи кількості кімнат → `Stage_Premises` → `usp_ETL_ApplyPremisesSCD2` закриває стару версію (`ValidTo`, `IsCurrent = 0`) і додає нову |

## Обробка помилок, логування, відновлення

- **Відбраковані рядки** — якщо не знайдено ключ виміру або суми некоректні, рядок не зупиняє пакет: через Lookup No Match Output / Conditional Split він потрапляє в Union All і записується в `ETL_ErrorRow` з причиною.
- **Помилки пакета** — Event Handler `OnError` записує джерело, код і опис помилки в `ETL_ErrorLog` і позначає запуск як `Failed`.
- **Журнал SSIS** — log provider «SSIS log provider for SQL Server» пише події `OnPreExecute`, `OnPostExecute`, `OnWarning`, `OnError` у таблицю `RentalDW.dbo.sysssislog`.
- **Аудит** — `ETL_Audit` (запуски), `ETL_RowCount` (рядки по таблицях), представлення `vw_ETL_RunSummary`; готові запити — `DataWarehouse/ETL_REPORTS.sql`.
- **Відновлення після збою** — контрольні точки (checkpoints) у файлі `C:\Users\Public\Rental_ETL.chk`. Після збою повторний запуск продовжує з задачі, що впала. Після успішного запуску файл видаляється автоматично.
- **Оцінка якості** — Script Task «Оцінка якості ETL» порівнює розбіжності зі звірки з кількістю відбракованих рядків і встановлює статус запуску (`ScriptTask_QualityCheck.cs`).

## Генератор пакета (`generator/`)

XML пакета (`Rental_ETL.dtsx`) згенеровано Python-скриптом, щоб структура потоків, імена колонок і метадані були узгоджені з таблицями сховища. Пакет повністю відкривається, редагується та запускається у Visual Studio.

```
python generator/build.py SSIS_Projects/Rental_SSIS --package-only
```

- `dtsxlib.py` — опис компонентів Data Flow (джерела, трансформації, призначення) у форматі SSIS;
- `build.py` — сам пакет: змінні, задачі, потоки даних, SQL-запити;
- `templates/ScriptTask_QualityCheck.xml` — Script Task, створений у дизайнері VS (C#-проєкт зберігається всередині задачі);
- `templates/Layout.xml` — розташування елементів на схемі, як їх розставлено у VS.

⚠️ Якщо пакет змінено у VS і збережено, а потім перегенеровано скриптом, ручні зміни зникнуть (крім Script Task і розташування — їх треба оновити в `templates/`).
