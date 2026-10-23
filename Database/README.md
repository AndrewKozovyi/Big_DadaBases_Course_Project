# База даних Rental (OLTP)

Курсова робота «Надвеликі бази даних», варіант 2 — «Оренда приміщень».

Тут лежать скрипти створення OLTP-бази `Rental`. Це джерело даних для подальшого ETL (SSIS) у сховище `RentalDW`.

## Що потрібно

- SQL Server 2022 (Developer) з компонентом Database Engine
- SQL Server Management Studio 20
- Підключення під SQL Server Authentication: логін `sa`, увімкнена галочка **Trust server certificate**. Потрібні права на створення бази, у `sa` вони є.

## Покрокове створення бази

1. Відкрийте SSMS і підключіться до сервера (наприклад, `ANDRUSHA`) під `sa`.
2. Для кожного скрипта з таблиці нижче, строго по порядку:
   - **File → Open → File…** (`Ctrl+O`) → виберіть скрипт у цій папці;
   - натисніть **Execute** (`F5`);
   - переконайтеся, що внизу написано *Query executed successfully*, а у вкладці **Messages** немає червоних помилок.
3. Виконайте перевірочний запит із розділу [Перевірка](#перевірка).

| № | Скрипт | Що робить |
|---|---|---|
| 1 | `CREATE_DATABASE.sql` | Створює базу `Rental`: українське порівняння рядків `Ukrainian_100_CI_AS`, режим відновлення `SIMPLE`, щоб журнал не розростався під час генерації даних. |
| 2 | `CREATE_TABLES.sql` | Створює 8 таблиць зі стовпцями та первинними ключами. ⚠️ Спочатку видаляє наявні таблиці разом з даними. |
| 3 | `CREATE_CONSTRAINTS.sql` | Додає зовнішні ключі, а також UNIQUE, CHECK і DEFAULT. Запускати одразу після кроку 2, поки таблиці порожні. |
| 4 | `CREATE_INDEXES.sql` | Створює 9 некластерних індексів на зовнішні ключі та під звіти. |
| 5 | `INSERT_LOOKUPS.sql` | Заповнює довідники з фіксованими ID: `TenantType` (3 записи) і `InvoiceStatus` (4 записи). |
| 6 | `CREATE_TRIGGERS.sql` | Створює функцію `fn_CalcInvoiceStatus` і 3 тригери бізнес-правил. |
| 7 | `CREATE_PROCEDURES.sql` | Створює 2 функції та 11 процедур: бізнес-операції і звіти. Потребує функції `fn_CalcInvoiceStatus` з кроку 6. |

Типи приміщень (`PremisesType`, 18 записів) і решта таблиць заповнюються на етапі генерації даних — див. [`../DataGeneration/README.md`](../DataGeneration/README.md).

## Перевірка

```sql
USE [Rental];

SELECT type_desc AS ObjectType, COUNT(*) AS Cnt
FROM sys.objects
WHERE is_ms_shipped = 0
  AND type IN ('U', 'TR', 'FN', 'IF', 'P')
GROUP BY type_desc;

SELECT * FROM dbo.TenantType;
SELECT * FROM dbo.InvoiceStatus;
```

Очікуваний результат:

| ObjectType | Cnt |
|---|---|
| USER_TABLE | 8 |
| SQL_TRIGGER | 3 |
| SQL_SCALAR_FUNCTION | 2 |
| SQL_INLINE_TABLE_VALUED_FUNCTION | 1 |
| SQL_STORED_PROCEDURE | 11 |

Тестування обмежень і тригерів — `TEST_CONSTRAINTS.sql`: спроби вставити некоректні дані в транзакції з `ROLLBACK`. Очікувані помилки: `50001` (тригер `TR_Contract_Validate`, перетин договорів) і порушення `CK_Tenant_Phone`. Дані не змінюються.

## Повторний запуск

- `CREATE_DATABASE.sql` створює базу лише тоді, коли її ще немає. Повторно запускати безпечно.
- `CREATE_TABLES.sql` **видаляє всі таблиці й дані**. Після нього треба знову виконати кроки 3–7: тригери видаляються разом із таблицями, а обмеження й індекси створюються лише на нових таблицях.
- `CREATE_CONSTRAINTS.sql` розрахований лише на щойно створені таблиці. Повторний запуск без кроку 2 завершиться помилкою «об'єкт уже існує».
- `CREATE_INDEXES.sql`, `INSERT_LOOKUPS.sql`, `CREATE_TRIGGERS.sql`, `CREATE_PROCEDURES.sql` можна запускати повторно: вони перестворюють або оновлюють свої об'єкти.

## Структура

| Таблиця | Призначення | План записів |
|---|---|---|
| `PremisesType` | Типи приміщень (квартира, офіс, склад …) | 18 |
| `Premises` | Приміщення: місто, адреса, поверх, кімнати, площа, ціна | 5 000 |
| `TenantType` | Типи орендарів (Фізична особа, ФОП, Юридична особа) | 3 |
| `Tenant` | Орендарі | 50 000 |
| `Contract` | Договори оренди | 100 000 |
| `InvoiceStatus` | Статуси рахунків | 4 |
| `Invoice` | Щомісячні рахунки | 210 000 |
| `Payment` | Платежі за рахунками | ≈ 195 000 |

Зв'язки (усі «один до багатьох»): `PremisesType → Premises → Contract ← Tenant ← TenantType`, `Contract → Invoice ← InvoiceStatus`, `Invoice → Payment`.

## Бізнес-правила в тригерах

Ці правила не виразити через CHECK, UNIQUE чи FOREIGN KEY, тому вони реалізовані тригерами:

1. Одне приміщення не можна здати за двома договорами з періодами, що перетинаються (`TR_Contract_Validate`).
2. Рахунок виставляється лише за місяць, у якому діяв договір. Змінити дати договору так, щоб рахунки випали з періоду, не можна (`TR_Contract_Validate`, `TR_Invoice_Validate`).
3. Сума платежів за рахунком не може перевищувати суму рахунку, а платіж не може бути раніше дати виставлення рахунку (`TR_Payment_RecalcInvoice`).
4. Статус рахунку перераховується автоматично після кожної зміни платежів або сум рахунку (`TR_Invoice_Validate`, `TR_Payment_RecalcInvoice`).

## Функції та процедури

**Функції**

| Об'єкт | Що повертає |
|---|---|
| `fn_CalcInvoiceStatus` | Статус рахунку за сумою, сплаченим і терміном оплати |
| `fn_TenantDebt` | Борг орендаря на дату |
| `fn_PremisesStateOnDate` | Стан усіх приміщень на дату (вільне / орендоване) |

**Бізнес-операції**

| Процедура | Що робить |
|---|---|
| `sp_CreateContract` | Оформлює договір оренди. Ціна за замовчуванням дорівнює поточній ціні приміщення, номер формується як `CN-<рік>-<ID>`. |
| `sp_TerminateContract` | Достроково розриває договір. |
| `sp_GenerateMonthlyInvoices` | Виставляє рахунки за місяць. Неповний місяць оплачується пропорційно, комунальні рахуються як площа × тариф. Термін оплати не раніше початку оренди. |
| `sp_RegisterPayment` | Реєструє платіж. |
| `sp_ApplyPenalties` | Нараховує пеню за прострочку (за замовчуванням 0,1 % за день, не більше ніж за 180 днів). |
| `sp_RefreshInvoiceStatuses` | Перераховує статуси рахунків на дату. |

**Звіти (обов'язкові звіти варіанту 2)**

| № | Звіт | Процедура |
|---|---|---|
| 1 | Список орендарів з інформацією про оренду та борги | `sp_GetTenantsWithDebts @AsOfDate, @OnlyDebtors` |
| 2 | Стан приміщень на певну дату | `sp_GetPremisesStateOnDate @Date, @City, @TypeID` |
| 3 | Довідка орендаря про історію оренди та платежів | `sp_GetTenantHistory @TenantID` |
| 4 | Аналіз завантаженості приміщень | `sp_GetPremisesOccupancy @DateFrom, @DateTo, @City, @TypeID` |
| 5 | Фінансовий звіт по орендарях | `sp_GetTenantFinancialReport @DateFrom, @DateTo, @TenantTypeID` |

Приклади:

```sql
EXEC dbo.sp_GetTenantsWithDebts @AsOfDate = '2025-12-31', @OnlyDebtors = 1;
EXEC dbo.sp_GetPremisesStateOnDate @Date = '2025-06-01', @City = N'Львів';
EXEC dbo.sp_GetPremisesOccupancy @DateFrom = '2025-01-01', @DateTo = '2025-12-31';
```

## Коди помилок бізнес-правил

| Код | Де виникає | Значення |
|---|---|---|
| 50001 | `TR_Contract_Validate` | Приміщення вже орендоване в цей період |
| 50002 | `TR_Contract_Validate` | Нові дати договору залишають рахунки поза періодом оренди |
| 50010 | `TR_Invoice_Validate` | Рахунок за місяць, у якому договір не діяв |
| 50011 | `TR_Invoice_Validate` | Сума рахунку менша за вже сплачене |
| 50020 | `TR_Payment_RecalcInvoice` | Дата платежу раніша за дату рахунку |
| 50021 | `TR_Payment_RecalcInvoice` | Переплата за рахунком |
| 50030 | `sp_CreateContract` | Приміщення не знайдено |
| 50031 | `sp_TerminateContract` | Договір не знайдено |
| 50032 | `sp_TerminateContract` | Договір уже розірвано |
| 50040, 50041 | Звіти за період | Кінець періоду раніший за початок |

## Масове завантаження даних

Тригери обробляють дані наборами, але на сотнях тисяч рядків помітно сповільнюють вставку. Тому на час генерації даних їх варто вимкнути, а після завантаження увімкнути й перерахувати статуси:

```sql
DISABLE TRIGGER ALL ON dbo.Contract;
DISABLE TRIGGER ALL ON dbo.Invoice;
DISABLE TRIGGER ALL ON dbo.Payment;

-- ... завантаження даних ...

ENABLE TRIGGER ALL ON dbo.Contract;
ENABLE TRIGGER ALL ON dbo.Invoice;
ENABLE TRIGGER ALL ON dbo.Payment;

EXEC dbo.sp_RefreshInvoiceStatuses;
```

Поки тригери вимкнені, правила з розділу [Бізнес-правила в тригерах](#бізнес-правила-в-тригерах) не перевіряються. Тому генератор має сам дотримуватися їх, а після завантаження це підтверджується перевірочними запитами.
