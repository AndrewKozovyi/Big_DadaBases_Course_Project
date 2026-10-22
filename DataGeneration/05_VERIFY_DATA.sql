USE [Rental];
GO

SET NOCOUNT ON;

/* =====================================================================
   1. Кількість записів
      Вимоги ТЗ: ≥ 500 000 у таблицях фактів, ≥ 5 000 приміщень,
      ≥ 100 000 операцій оренди, історія за 5 років
   ===================================================================== */
WITH Counts AS (
    SELECT N'Довідник' AS Kind, N'PremisesType'  AS TableName, COUNT(*) AS RowsCount FROM dbo.PremisesType
    UNION ALL SELECT N'Довідник', N'Premises',      COUNT(*) FROM dbo.Premises
    UNION ALL SELECT N'Довідник', N'TenantType',    COUNT(*) FROM dbo.TenantType
    UNION ALL SELECT N'Довідник', N'Tenant',        COUNT(*) FROM dbo.Tenant
    UNION ALL SELECT N'Довідник', N'InvoiceStatus', COUNT(*) FROM dbo.InvoiceStatus
    UNION ALL SELECT N'Факти',    N'Contract',      COUNT(*) FROM dbo.Contract
    UNION ALL SELECT N'Факти',    N'Invoice',       COUNT(*) FROM dbo.Invoice
    UNION ALL SELECT N'Факти',    N'Payment',       COUNT(*) FROM dbo.Payment
)
SELECT Kind, TableName, RowsCount FROM Counts
UNION ALL
SELECT N'Разом', Kind, SUM(RowsCount) FROM Counts GROUP BY Kind
UNION ALL
SELECT N'Разом', N'Уся база', SUM(RowsCount) FROM Counts;

SELECT
    MIN(StartDate)                                 AS FirstContractStart,
    MAX(StartDate)                                 AS LastContractStart,
    (SELECT MIN(PeriodMonth) FROM dbo.Invoice)     AS FirstInvoiceMonth,
    (SELECT MAX(PeriodMonth) FROM dbo.Invoice)     AS LastInvoiceMonth,
    (SELECT MAX(PaymentDate) FROM dbo.Payment)     AS LastPaymentDate
FROM dbo.Contract;

/* =====================================================================
   2. Перевірки цілісності — у кожному рядку має бути 0
   ===================================================================== */
SELECT N'Перетин договорів одного приміщення' AS CheckName, COUNT(*) AS Violations
FROM dbo.Contract AS a
JOIN dbo.Contract AS b
  ON  a.PremisesID = b.PremisesID
  AND a.ContractID < b.ContractID
  AND a.StartDate <= COALESCE(b.TerminationDate, b.EndDate)
  AND b.StartDate <= COALESCE(a.TerminationDate, a.EndDate)
UNION ALL
SELECT N'Рахунок поза періодом дії договору', COUNT(*)
FROM dbo.Invoice AS i
JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
WHERE i.PeriodMonth > COALESCE(c.TerminationDate, c.EndDate)
   OR EOMONTH(i.PeriodMonth) < c.StartDate
UNION ALL
SELECT N'Переплата за рахунком', COUNT(*)
FROM dbo.Invoice AS i
CROSS APPLY (SELECT SUM(p.Amount) AS Paid FROM dbo.Payment AS p WHERE p.InvoiceID = i.InvoiceID) AS s
WHERE s.Paid > i.TotalAmount
UNION ALL
SELECT N'Платіж раніше дати рахунку', COUNT(*)
FROM dbo.Payment AS p
JOIN dbo.Invoice AS i ON i.InvoiceID = p.InvoiceID
WHERE p.PaymentDate < i.IssueDate
UNION ALL
SELECT N'Термін оплати раніше початку оренди', COUNT(*)
FROM dbo.Invoice AS i
JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
WHERE i.DueDate < c.StartDate
UNION ALL
SELECT N'Статус рахунку не відповідає платежам', COUNT(*)
FROM dbo.Invoice AS i
OUTER APPLY (SELECT SUM(p.Amount) AS Paid FROM dbo.Payment AS p WHERE p.InvoiceID = i.InvoiceID) AS s
WHERE i.StatusID <> dbo.fn_CalcInvoiceStatus(i.TotalAmount, ISNULL(s.Paid, 0), i.DueDate, CAST(GETDATE() AS DATE))
UNION ALL
SELECT N'Орендар без жодного договору', COUNT(*)
FROM dbo.Tenant AS t
WHERE NOT EXISTS (SELECT 1 FROM dbo.Contract AS c WHERE c.TenantID = t.TenantID);

-- Перевірка всіх CHECK і FOREIGN KEY обмежень на наявних даних (порожній результат = помилок немає)
DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS;

/* =====================================================================
   3. Реалістичність даних
   ===================================================================== */

-- Рахунки за статусами
SELECT
    st.Name                                   AS InvoiceStatus,
    COUNT(*)                                  AS Invoices,
    SUM(i.TotalAmount)                        AS Invoiced,
    SUM(i.TotalAmount - ISNULL(s.Paid, 0))    AS Debt
FROM dbo.Invoice AS i
JOIN dbo.InvoiceStatus AS st ON st.StatusID = i.StatusID
OUTER APPLY (SELECT SUM(p.Amount) AS Paid FROM dbo.Payment AS p WHERE p.InvoiceID = i.InvoiceID) AS s
GROUP BY st.StatusID, st.Name
ORDER BY st.StatusID;

-- Динаміка по роках: кількість договорів, середня ціна оренди, нараховано та сплачено
SELECT
    y.[Year],
    c.Contracts,
    c.AvgMonthlyRent,
    i.Invoiced,
    p.Paid
FROM (SELECT DISTINCT YEAR(PeriodMonth) AS [Year] FROM dbo.Invoice) AS y
OUTER APPLY (SELECT COUNT(*) AS Contracts, CAST(AVG(MonthlyRent) AS DECIMAL(12,2)) AS AvgMonthlyRent
             FROM dbo.Contract WHERE YEAR(StartDate) = y.[Year]) AS c
OUTER APPLY (SELECT SUM(TotalAmount) AS Invoiced
             FROM dbo.Invoice WHERE YEAR(PeriodMonth) = y.[Year]) AS i
OUTER APPLY (SELECT SUM(Amount) AS Paid
             FROM dbo.Payment WHERE YEAR(PaymentDate) = y.[Year]) AS p
ORDER BY y.[Year];

-- Стан приміщень на сьогодні
SELECT State, COUNT(*) AS Premises
FROM dbo.fn_PremisesStateOnDate(CAST(GETDATE() AS DATE))
GROUP BY State;

-- Орендарі за типами
SELECT tt.Name AS TenantType, COUNT(*) AS Tenants
FROM dbo.Tenant AS t
JOIN dbo.TenantType AS tt ON tt.TenantTypeID = t.TenantTypeID
GROUP BY tt.Name;

-- Приміщення за типами
SELECT
    pt.Name                                   AS PremisesType,
    COUNT(*)                                  AS Premises,
    MIN(p.Floor)                              AS MinFloor,
    MAX(p.Floor)                              AS MaxFloor,
    CAST(AVG(p.Area) AS DECIMAL(9,1))         AS AvgArea,
    CAST(AVG(p.MonthlyPrice) AS DECIMAL(12,2)) AS AvgMonthlyPrice
FROM dbo.Premises AS p
JOIN dbo.PremisesType AS pt ON pt.TypeID = p.TypeID
GROUP BY pt.TypeID, pt.Name
ORDER BY pt.TypeID;

-- Хто орендує: житло — фізичні особи, решта — ФОП і юридичні особи
SELECT
    pt.Name   AS PremisesType,
    tt.Name   AS TenantType,
    COUNT(*)  AS Contracts
FROM dbo.Contract AS c
JOIN dbo.Premises AS p      ON p.PremisesID = c.PremisesID
JOIN dbo.PremisesType AS pt ON pt.TypeID = p.TypeID
JOIN dbo.Tenant AS t        ON t.TenantID = c.TenantID
JOIN dbo.TenantType AS tt   ON tt.TenantTypeID = t.TenantTypeID
GROUP BY pt.TypeID, pt.Name, tt.TenantTypeID, tt.Name
ORDER BY pt.TypeID, tt.TenantTypeID;

-- Приміщення за містами
SELECT City, COUNT(*) AS Premises, CAST(AVG(MonthlyPrice) AS DECIMAL(12,2)) AS AvgMonthlyPrice
FROM dbo.Premises
GROUP BY City
ORDER BY Premises DESC;

-- Приклади записів
SELECT TOP (10) * FROM dbo.Premises ORDER BY NEWID();
SELECT TOP (10) * FROM dbo.Tenant   ORDER BY NEWID();
SELECT TOP (10) * FROM dbo.Contract ORDER BY NEWID();
GO
