# Звіти (SSRS)

Курсова робота «Надвеликі бази даних», варіант 2 — «Оренда приміщень».

Проєкт Reporting Services `Rental_SSRS` містить 7 звітів і 1 підзвіт. Усі дані беруться зі сховища: аналітичні звіти — з OLAP-куба «Оренда» (`Rental_SSAS`, побудований над `RentalDW`), документні звіти (стан на дату, довідка орендаря з окремими рахунками й платежами) — SQL-запитами до сховища `RentalDW`. До OLTP-бази `Rental` звіти не звертаються.

## Склад папки

| Шлях | Що це |
|---|---|
| `Rental_SSRS/Rental_SSRS.sln`, `Rental_SSRS/Rental_SSRS/Rental_SSRS.rptproj` | Рішення та проєкт Visual Studio (Report Server Project) |
| `RentalCube.rds` | Спільне джерело даних: Analysis Services (`OLEDB-MD`), `Data Source=ANDRUSHA; Initial Catalog=Rental_SSAS`, Windows-автентифікація |
| `RentalDW.rds` | Спільне джерело даних: SQL Server, сховище `Data Source=ANDRUSHA; Initial Catalog=RentalDW`, Windows-автентифікація |
| `TenantTypes.rsd`, `TypeGroups.rsd`, `Years.rsd`, `YearsLast3.rsd` | Спільні набори даних (MDX) для списків параметрів |
| `01 … 07 *.rdl`, `03a *.rdl` | Звіти |
| `../DataWarehouse/CREATE_DW_REPORT_OBJECTS.sql` | Об'єкти сховища для документних звітів: `vw_ContractInfo`, `fn_PremisesStateOnDate`, індекси |

## Звіти

| № | Звіт | Тип (ТЗ 5.2) | Джерело | Параметри |
|---|---|---|---|---|
| 01 | **Список орендарів з інформацією про оренду та борги** | Табличний: групування за типом орендаря, підсумки груп і загальний, сортування | Куб | Період з / по (діапазон з перевіркою), Тип орендаря (мультивибір), Лише боржники (Boolean) |
| 02 | **Стан приміщень на певну дату** | Табличний, розрив сторінки на кожне місто | Сховище, `dbo.fn_PremisesStateOnDate` (версії SCD2 на дату) | Дата, Місто (мультивибір) → Тип приміщення (каскадний), Лише вільні (Boolean) |
| 03 | **Довідка орендаря про історію оренди та платежів** | Документ із підзвітом | Сховище (`Dim_Tenant`, `vw_ContractInfo`, `Fact_Invoice`) | Тип орендаря (dropdown) → Пошук → Орендар (каскадний) |
| 03a | Рахунки та платежі договору | Підзвіт у звіті 03; платежі розгортаються (toggle) | Сховище (`Fact_Invoice`, `Fact_Payment`) | ID договору |
| 04 | **Аналіз завантаженості приміщень** | Матричний і drill-down: група → тип → місто × рік → квартал → місяць, теплова карта | Куб | Роки, Групи типів (мультивибір) |
| 05 | **Фінансовий звіт по орендарях** | Матричний і drill-down: тип орендаря → орендар × роки; drillthrough на 03 | Куб | Роки, Тип орендаря (мультивибір), Топ-N (dropdown) |
| 06 | Динаміка доходів і платежів | Діаграми: Column, Line, Pie, Bar | Куб | Період з / по (діапазон з перевіркою), Групи типів |
| 07 | Панель керівника | Дашборд: картки, 3 Gauges для KPI, індикатори статусу й тренду, Sparklines, матриця, діаграма | Куб | Рік (dropdown) |

Звіти 01–05 відповідають п'яти обов'язковим звітам варіанту 2. Звіти 06 і 07 покривають типи «Діаграми» та «Дашборд».

## Відповідність вимогам ТЗ (етап 5)

### 5.1 Проєкт SSRS

- Report Server Project `Rental_SSRS`.
- Shared Data Source `RentalCube` підключається до OLAP-куба. `RentalDW` — друге спільне джерело, до самого сховища, для документних звітів 02, 03 і 03a: кубу потрібні агрегати, а документам — окремі рахунки й платежі, яких куб не зберігає.
- Договори, за якими ще не виставлено жодного рахунку, у довідку не потрапляють: у `Dim_Contract` немає ключів орендаря й приміщення, вони беруться з рахунків (як в іменованому запиті `Contract_Facts` куба).
- Спільні набори даних (`.rsd`) для параметрів.

### 5.2 Типи звітів

| Вимога | Де |
|---|---|
| Табличний: групування, підсумки, сортування | 01 (групи за типом орендаря, підсумок групи й загальний, сортування за боргом і клацанням на заголовку), 02 |
| Матричний | 04, 05 |
| Діаграми (мінімум 3 типи) | 06: Column, Line, Pie, Bar; у 07 — комбінована Column + Line |
| Дашборд: таблиці, матриця, діаграми, KPI, Gauges, Sparklines | 07 |
| Drill-down: розгортання й згортання, рівні деталізації, drillthrough | 04 (рядки й колонки), 05 (тип → орендар), 03a (рахунок → платежі). Drillthrough: 01, 02, 05 → 03; 06 (стовпчик року) і 07 (картка «Борг») → 01; 07 (завантаженість міста) → 04 |

### 5.3 Параметри

| Тип | Де |
|---|---|
| Dropdown зі значеннями з набору даних | Рік (07), Тип орендаря (03), Топ-N (05) |
| Multi-select з «Select All» | Типи орендарів (01, 05), Групи типів (04, 06), Роки (04, 05), Міста й типи приміщень (02) |
| Date Range з валідацією | «Період з / по» (01, 06). Якщо початок пізніший за кінець, звіт показує попередження замість даних. Перевірку виконує функція `Code.BadRange` |
| Cascading | Місто → Тип приміщення (02); Тип орендаря + Пошук → Орендар (03) |
| Boolean | Лише боржники (01), Лише вільні приміщення (02) |

### 5.4 Додаткова функціональність

| Вимога | Де |
|---|---|
| Conditional formatting | Борг червоним; рівень оплати і KPI — світлофор (`Code.KpiColor`); теплова карта завантаженості (`Code.Heat`); стан приміщення й договору; прострочення понад 30 днів |
| Interactive sorting | Заголовки колонок у 01, 02, 05, 07 |
| Toggle items | 03a, 04, 05 |
| Document map | 01 (типи орендарів), 02 (міста), 03 (договори), 04 (групи типів) |
| Export PDF / Excel / Word | Вбудований експорт SSRS. Розмітка розрахована на A4 (01, 02, 04–07 — альбомна, 03 — книжкова). У 01 і 02 `PageName` дає окремий аркуш Excel на кожну групу |
| Subreports | 03a всередині 03 |
| Page breaks | Між типами орендарів (01), між містами (02), перед кожним договором (03) |

### 5.5 Розгортання

| Вимога | Де |
|---|---|
| Публікація на Report Server | Deploy з Visual Studio у `http://localhost/reportserver` |
| Організація папок | `/Rental_SSRS/Звіти`, `/Rental_SSRS/Datasets`, `/Rental_SSRS/Data Sources` |
| Безпека й доступ | Портал: на папку `Rental_SSRS` — Content Manager для адміністраторів і власника, Browser для групи «Користувачі»; звіт 07 — лише адміністратори (без успадкування) |
| Кешування | Звіти 06 і 07 — кеш 60 хв; план оновлення кешу 07 щодня о 07:00 |
| Subscriptions | Звіт 05 у PDF щодня о 08:00 у мережеву папку `\\<комп'ютер>\SSRS_Subscriptions` (File Share), перевірено тестовим запуском |

## Розгортання

1. **Об'єкти сховища для звітів** (один раз): SSMS → `DataWarehouse/CREATE_DW_REPORT_OBJECTS.sql` → F5.
2. **Report Server Configuration Manager** (якщо SSRS ще не налаштований):
   - Web Service URL → Apply (`http://<комп'ютер>:80/ReportServer`);
   - Database → Change Database → Create a new report server database → сервер `ANDRUSHA`, база `ReportServer`, Service Credentials;
   - Web Portal URL → Apply (`http://<комп'ютер>:80/Reports`).
3. **Права на сервері звітів** (якщо VS під час Deploy просить логін і пароль). Chrome від імені адміністратора → `http://localhost/reports`:
   - шестерня → Site settings → Security → обліковий запис Windows — **System Administrator**;
   - Home → Manage folder → Security → той самий обліковий запис — **Content Manager**.
4. **Visual Studio** (від імені адміністратора) → `Rental_SSRS.sln` → **Build → Deploy Rental_SSRS**. Налаштування проєкту:
   - TargetServerURL: `http://localhost/reportserver`;
   - звіти: `Rental_SSRS/Звіти`;
   - набори даних: `Rental_SSRS/Datasets`;
   - джерела: `Rental_SSRS/Data Sources`.
5. **Облікові дані джерел** (потрібні для кешу й підписок). Портал → `Rental_SSRS/Data Sources` → `RentalCube`, потім `RentalDW` → Manage:
   - «Using the following credentials» → **Windows user name and password**;
   - обліковий запис Windows і пароль (не PIN);
   - Test connection → Apply.
6. **Безпека.** Портал:
   - `Rental_SSRS` → Manage → Security → Customize security → Add group or user:
     - адміністратори — Content Manager;
     - група «Користувачі» (`BUILTIN\Users`) — Browser;
   - звіт `07 Панель керівника` → Manage → Security → Customize security → залишити лише адміністраторів.
7. **Кешування.** Портал → звіти `06` і `07` → Manage → Caching:
   - «Cache copies of this report and use them when available» → expire after 60 minutes;
   - для `07` додатково: Cache refresh plans → New → щодня о 07:00.
8. **Підписка.** Створити спільну папку `C:\SSRS_Subscriptions` (Sharing → `\\<комп'ютер>\SSRS_Subscriptions`). Портал → `05 Фінансовий звіт по орендарях` → Subscribe:
   - Delivery: **Windows File Share**, шлях `\\<комп'ютер>\SSRS_Subscriptions`, формат PDF, Overwrite, облікові дані Windows;
   - розклад щодня о 08:00.

   Потрібен запущений SQL Server Agent. Перевірка: Manage → Subscriptions → Run now; у папці з'являється `Фінансовий звіт по орендарях.pdf`.
9. **Перевірка й експорт:** портал `http://localhost/reports` → `Rental_SSRS/Звіти` → кожен звіт → Export → PDF / Excel / Word.
