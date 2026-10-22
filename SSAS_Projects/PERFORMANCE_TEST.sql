-- Тест продуктивності: однакові аналітичні запити до OLTP (Rental) і сховища (RentalDW).
-- Ті самі питання для куба — PERFORMANCE_TEST.mdx. Результати — у SSAS_Projects/README.md.
-- Кожен запит виконується двічі: з холодним кешем (CHECKPOINT + DBCC DROPCLEANBUFFERS) і з теплим.
-- Результати запитів пишуться в тимчасові таблиці, на екран виводиться лише таблиця часу.
-- DBCC DROPCLEANBUFFERS очищає кеш даних сервера — запускати лише на навчальному сервері.

SET NOCOUNT ON;
DECLARE @t DATETIME2, @cold INT;
DECLARE @Perf TABLE (Query NVARCHAR(100), ColdMs INT, WarmMs INT, ResultRows INT);

/* 1 OLTP: сума і сплачено по роках і групах типів */
CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET @t = SYSDATETIME();
SELECT * INTO #c1 FROM (SELECT YEAR(i.PeriodMonth) AS [Year],
           CASE WHEN pt.Name IN (N'Квартира', N'Будинок', N'Кімната') THEN N'Житло'
                WHEN pt.Name IN (N'Офіс', N'Коворкінг', N'Конференц-зал') THEN N'Офіси'
                WHEN pt.Name IN (N'Склад', N'Виробниче приміщення', N'Майстерня') THEN N'Склад і виробництво'
                WHEN pt.Name IN (N'Гараж', N'Паркомісце') THEN N'Авто'
                ELSE N'Торгівля та послуги' END AS TypeGroup,
           SUM(i.TotalAmount) AS Total, SUM(ISNULL(p.Paid, 0)) AS Paid
    FROM Rental.dbo.Invoice AS i
    JOIN Rental.dbo.Contract AS c ON c.ContractID = i.ContractID
    JOIN Rental.dbo.Premises AS pr ON pr.PremisesID = c.PremisesID
    JOIN Rental.dbo.PremisesType AS pt ON pt.TypeID = pr.TypeID
    LEFT JOIN (SELECT InvoiceID, SUM(Amount) AS Paid FROM Rental.dbo.Payment GROUP BY InvoiceID) AS p
           ON p.InvoiceID = i.InvoiceID
    GROUP BY YEAR(i.PeriodMonth),
             CASE WHEN pt.Name IN (N'Квартира', N'Будинок', N'Кімната') THEN N'Житло'
                  WHEN pt.Name IN (N'Офіс', N'Коворкінг', N'Конференц-зал') THEN N'Офіси'
                  WHEN pt.Name IN (N'Склад', N'Виробниче приміщення', N'Майстерня') THEN N'Склад і виробництво'
                  WHEN pt.Name IN (N'Гараж', N'Паркомісце') THEN N'Авто'
                  ELSE N'Торгівля та послуги' END ) AS q;
SET @cold = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SET @t = SYSDATETIME();
SELECT * INTO #w1 FROM (SELECT YEAR(i.PeriodMonth) AS [Year],
           CASE WHEN pt.Name IN (N'Квартира', N'Будинок', N'Кімната') THEN N'Житло'
                WHEN pt.Name IN (N'Офіс', N'Коворкінг', N'Конференц-зал') THEN N'Офіси'
                WHEN pt.Name IN (N'Склад', N'Виробниче приміщення', N'Майстерня') THEN N'Склад і виробництво'
                WHEN pt.Name IN (N'Гараж', N'Паркомісце') THEN N'Авто'
                ELSE N'Торгівля та послуги' END AS TypeGroup,
           SUM(i.TotalAmount) AS Total, SUM(ISNULL(p.Paid, 0)) AS Paid
    FROM Rental.dbo.Invoice AS i
    JOIN Rental.dbo.Contract AS c ON c.ContractID = i.ContractID
    JOIN Rental.dbo.Premises AS pr ON pr.PremisesID = c.PremisesID
    JOIN Rental.dbo.PremisesType AS pt ON pt.TypeID = pr.TypeID
    LEFT JOIN (SELECT InvoiceID, SUM(Amount) AS Paid FROM Rental.dbo.Payment GROUP BY InvoiceID) AS p
           ON p.InvoiceID = i.InvoiceID
    GROUP BY YEAR(i.PeriodMonth),
             CASE WHEN pt.Name IN (N'Квартира', N'Будинок', N'Кімната') THEN N'Житло'
                  WHEN pt.Name IN (N'Офіс', N'Коворкінг', N'Конференц-зал') THEN N'Офіси'
                  WHEN pt.Name IN (N'Склад', N'Виробниче приміщення', N'Майстерня') THEN N'Склад і виробництво'
                  WHEN pt.Name IN (N'Гараж', N'Паркомісце') THEN N'Авто'
                  ELSE N'Торгівля та послуги' END ) AS q;
INSERT INTO @Perf VALUES (N'1 OLTP: сума і сплачено по роках і групах типів', @cold, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM #w1));

/* 1 DW: сума і сплачено по роках і групах типів */
CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET @t = SYSDATETIME();
SELECT * INTO #c2 FROM (SELECT d.[Year], p.TypeGroup, SUM(f.TotalAmount) AS Total, SUM(f.PaidAmount) AS Paid
    FROM RentalDW.dbo.Fact_Invoice AS f
    JOIN RentalDW.dbo.Dim_Date AS d ON d.DateKey = f.PeriodDateKey
    JOIN RentalDW.dbo.Dim_Premises AS p ON p.PremisesKey = f.PremisesKey
    GROUP BY d.[Year], p.TypeGroup ) AS q;
SET @cold = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SET @t = SYSDATETIME();
SELECT * INTO #w2 FROM (SELECT d.[Year], p.TypeGroup, SUM(f.TotalAmount) AS Total, SUM(f.PaidAmount) AS Paid
    FROM RentalDW.dbo.Fact_Invoice AS f
    JOIN RentalDW.dbo.Dim_Date AS d ON d.DateKey = f.PeriodDateKey
    JOIN RentalDW.dbo.Dim_Premises AS p ON p.PremisesKey = f.PremisesKey
    GROUP BY d.[Year], p.TypeGroup ) AS q;
INSERT INTO @Perf VALUES (N'1 DW: сума і сплачено по роках і групах типів', @cold, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM #w2));

/* 2 OLTP: топ-10 боржників */
CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET @t = SYSDATETIME();
SELECT * INTO #c3 FROM (SELECT TOP (10) t.TenantID, t.Name, SUM(i.TotalAmount - ISNULL(p.Paid, 0)) AS Debt
    FROM Rental.dbo.Invoice AS i
    JOIN Rental.dbo.Contract AS c ON c.ContractID = i.ContractID
    JOIN Rental.dbo.Tenant AS t ON t.TenantID = c.TenantID
    LEFT JOIN (SELECT InvoiceID, SUM(Amount) AS Paid FROM Rental.dbo.Payment GROUP BY InvoiceID) AS p
           ON p.InvoiceID = i.InvoiceID
    GROUP BY t.TenantID, t.Name
    ORDER BY Debt DESC ) AS q;
SET @cold = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SET @t = SYSDATETIME();
SELECT * INTO #w3 FROM (SELECT TOP (10) t.TenantID, t.Name, SUM(i.TotalAmount - ISNULL(p.Paid, 0)) AS Debt
    FROM Rental.dbo.Invoice AS i
    JOIN Rental.dbo.Contract AS c ON c.ContractID = i.ContractID
    JOIN Rental.dbo.Tenant AS t ON t.TenantID = c.TenantID
    LEFT JOIN (SELECT InvoiceID, SUM(Amount) AS Paid FROM Rental.dbo.Payment GROUP BY InvoiceID) AS p
           ON p.InvoiceID = i.InvoiceID
    GROUP BY t.TenantID, t.Name
    ORDER BY Debt DESC ) AS q;
INSERT INTO @Perf VALUES (N'2 OLTP: топ-10 боржників', @cold, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM #w3));

/* 2 DW: топ-10 боржників */
CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET @t = SYSDATETIME();
SELECT * INTO #c4 FROM (SELECT TOP (10) t.TenantID, t.Name, SUM(f.DebtAmount) AS Debt
    FROM RentalDW.dbo.Fact_Invoice AS f
    JOIN RentalDW.dbo.Dim_Tenant AS t ON t.TenantKey = f.TenantKey
    GROUP BY t.TenantID, t.Name
    ORDER BY Debt DESC ) AS q;
SET @cold = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SET @t = SYSDATETIME();
SELECT * INTO #w4 FROM (SELECT TOP (10) t.TenantID, t.Name, SUM(f.DebtAmount) AS Debt
    FROM RentalDW.dbo.Fact_Invoice AS f
    JOIN RentalDW.dbo.Dim_Tenant AS t ON t.TenantKey = f.TenantKey
    GROUP BY t.TenantID, t.Name
    ORDER BY Debt DESC ) AS q;
INSERT INTO @Perf VALUES (N'2 DW: топ-10 боржників', @cold, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM #w4));

/* 3 OLTP: завантаженість по містах і місяцях 2025 */
CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET @t = SYSDATETIME();
SELECT * INTO #c5 FROM (SELECT p.City, m.MonthStart,
           SUM(CASE WHEN c.ContractID IS NULL THEN 0 ELSE
                   DATEDIFF(DAY,
                       CASE WHEN c.StartDate > m.MonthStart THEN c.StartDate ELSE m.MonthStart END,
                       CASE WHEN COALESCE(c.TerminationDate, c.EndDate) < EOMONTH(m.MonthStart)
                            THEN COALESCE(c.TerminationDate, c.EndDate) ELSE EOMONTH(m.MonthStart) END) + 1 END) * 1.0
             / (COUNT(DISTINCT p.PremisesID) * DAY(EOMONTH(m.MonthStart))) AS Occupancy
    FROM Rental.dbo.Premises AS p
    CROSS JOIN (SELECT DATEFROMPARTS(2025, v.m, 1) AS MonthStart
                FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12)) AS v(m)) AS m
    LEFT JOIN Rental.dbo.Contract AS c
           ON c.PremisesID = p.PremisesID
          AND c.StartDate <= EOMONTH(m.MonthStart)
          AND COALESCE(c.TerminationDate, c.EndDate) >= m.MonthStart
    GROUP BY p.City, m.MonthStart ) AS q;
SET @cold = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SET @t = SYSDATETIME();
SELECT * INTO #w5 FROM (SELECT p.City, m.MonthStart,
           SUM(CASE WHEN c.ContractID IS NULL THEN 0 ELSE
                   DATEDIFF(DAY,
                       CASE WHEN c.StartDate > m.MonthStart THEN c.StartDate ELSE m.MonthStart END,
                       CASE WHEN COALESCE(c.TerminationDate, c.EndDate) < EOMONTH(m.MonthStart)
                            THEN COALESCE(c.TerminationDate, c.EndDate) ELSE EOMONTH(m.MonthStart) END) + 1 END) * 1.0
             / (COUNT(DISTINCT p.PremisesID) * DAY(EOMONTH(m.MonthStart))) AS Occupancy
    FROM Rental.dbo.Premises AS p
    CROSS JOIN (SELECT DATEFROMPARTS(2025, v.m, 1) AS MonthStart
                FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12)) AS v(m)) AS m
    LEFT JOIN Rental.dbo.Contract AS c
           ON c.PremisesID = p.PremisesID
          AND c.StartDate <= EOMONTH(m.MonthStart)
          AND COALESCE(c.TerminationDate, c.EndDate) >= m.MonthStart
    GROUP BY p.City, m.MonthStart ) AS q;
INSERT INTO @Perf VALUES (N'3 OLTP: завантаженість по містах і місяцях 2025', @cold, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM #w5));

/* 3 DW: завантаженість по містах і місяцях 2025 */
CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;
SET @t = SYSDATETIME();
SELECT * INTO #c6 FROM (SELECT p.City, d.YearMonth, SUM(f.RentedDays) * 1.0 / SUM(f.DaysInMonth) AS Occupancy,
           SUM(f.RentIncome) AS Income
    FROM RentalDW.dbo.Fact_Occupancy AS f
    JOIN RentalDW.dbo.Dim_Date AS d ON d.DateKey = f.MonthDateKey
    JOIN RentalDW.dbo.Dim_Premises AS p ON p.PremisesKey = f.PremisesKey
    WHERE d.[Year] = 2025
    GROUP BY p.City, d.YearMonth ) AS q;
SET @cold = DATEDIFF(MILLISECOND, @t, SYSDATETIME());
SET @t = SYSDATETIME();
SELECT * INTO #w6 FROM (SELECT p.City, d.YearMonth, SUM(f.RentedDays) * 1.0 / SUM(f.DaysInMonth) AS Occupancy,
           SUM(f.RentIncome) AS Income
    FROM RentalDW.dbo.Fact_Occupancy AS f
    JOIN RentalDW.dbo.Dim_Date AS d ON d.DateKey = f.MonthDateKey
    JOIN RentalDW.dbo.Dim_Premises AS p ON p.PremisesKey = f.PremisesKey
    WHERE d.[Year] = 2025
    GROUP BY p.City, d.YearMonth ) AS q;
INSERT INTO @Perf VALUES (N'3 DW: завантаженість по містах і місяцях 2025', @cold, DATEDIFF(MILLISECOND, @t, SYSDATETIME()), (SELECT COUNT(*) FROM #w6));

SELECT Query AS [Запит], ColdMs AS [Холодний кеш, мс], WarmMs AS [Теплий кеш, мс], ResultRows AS [Рядків] FROM @Perf;
