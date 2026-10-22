USE [RentalDW];
GO

-- Звіти контролю якості ETL (ТЗ, п. 3.5): журнал запусків, кількість оброблених рядків,
-- помилки пакета, відбраковані рядки та звірка сховища з OLTP.
-- Кожен запит можна виконувати окремо (виділити й натиснути F5).

/* 1. Журнал запусків: режим, статус, тривалість, обсяг і висновок Script Task «Оцінка якості ETL» */
SELECT RunID, RequestedMode, LoadMode, Status, StartTime, EndTime, DurationSec,
       RowsInserted, RowsUpdated, RowsError, PackageErrors, LastInvoiceID, LastPaymentID, Message
FROM dbo.vw_ETL_RunSummary
ORDER BY RunID DESC;

/* 2. Кількість оброблених рядків по таблицях в останньому запуску */
SELECT r.TableName, r.RowsInserted, r.RowsUpdated, r.RowsError, r.LoggedAt
FROM dbo.ETL_RowCount AS r
WHERE r.RunID = (SELECT MAX(RunID) FROM dbo.ETL_Audit)
ORDER BY r.ID;

/* 3. Динаміка: скільки рядків кожна таблиця отримала в кожному запуску (зведена таблиця) */
SELECT r.RunID, a.LoadMode, a.Status,
       SUM(CASE WHEN r.TableName LIKE N'Fact_Invoice 20%' THEN r.RowsInserted ELSE 0 END) AS Invoices,
       SUM(CASE WHEN r.TableName = N'Fact_Payment'        THEN r.RowsInserted ELSE 0 END) AS Payments,
       SUM(CASE WHEN r.TableName = N'Fact_Occupancy'      THEN r.RowsInserted ELSE 0 END) AS Occupancy,
       SUM(CASE WHEN r.TableName LIKE N'Dim[_]%'          THEN r.RowsInserted ELSE 0 END) AS DimInserted,
       SUM(CASE WHEN r.TableName LIKE N'Dim[_]%'          THEN r.RowsUpdated  ELSE 0 END) AS DimUpdated,
       SUM(r.RowsError)                                                                  AS Rejected
FROM dbo.ETL_RowCount AS r
JOIN dbo.ETL_Audit    AS a ON a.RunID = r.RunID
GROUP BY r.RunID, a.LoadMode, a.Status
ORDER BY r.RunID DESC;

/* 4. Помилки виконання пакета (записує Event Handler OnError) */
SELECT TOP (50) e.ID, e.RunID, e.SourceName, e.ErrorCode, e.ErrorDescription, e.LoggedAt
FROM dbo.ETL_ErrorLog AS e
ORDER BY e.ID DESC;

/* 5. Відбраковані рядки даних за причинами */
SELECT er.RunID, er.SourceTable, er.ErrorReason, COUNT(*) AS RowsRejected
FROM dbo.ETL_ErrorRow AS er
GROUP BY er.RunID, er.SourceTable, er.ErrorReason
ORDER BY er.RunID DESC, RowsRejected DESC;

/* 6. Звірка сховища з OLTP: кількість рядків і суми */
SELECT N'Рахунки — кількість' AS [Перевірка],
       (SELECT COUNT(*) FROM Rental.dbo.Invoice) AS [OLTP],
       (SELECT COUNT(*) FROM dbo.Fact_Invoice)   AS [Сховище]
UNION ALL
SELECT N'Рахунки — сума',
       (SELECT SUM(TotalAmount) FROM Rental.dbo.Invoice),
       (SELECT SUM(TotalAmount) FROM dbo.Fact_Invoice)
UNION ALL
SELECT N'Платежі — кількість',
       (SELECT COUNT(*) FROM Rental.dbo.Payment),
       (SELECT COUNT(*) FROM dbo.Fact_Payment)
UNION ALL
SELECT N'Платежі — сума',
       (SELECT SUM(Amount) FROM Rental.dbo.Payment),
       (SELECT SUM(Amount) FROM dbo.Fact_Payment)
UNION ALL
SELECT N'Борг за рахунками',
       (SELECT SUM(i.TotalAmount) - (SELECT SUM(Amount) FROM Rental.dbo.Payment) FROM Rental.dbo.Invoice AS i),
       (SELECT SUM(DebtAmount) FROM dbo.Fact_Invoice)
UNION ALL
SELECT N'Орендарі',      (SELECT COUNT(*) FROM Rental.dbo.Tenant),   (SELECT COUNT(*) FROM dbo.Dim_Tenant)
UNION ALL
SELECT N'Приміщення (поточні версії)',
       (SELECT COUNT(*) FROM Rental.dbo.Premises),
       (SELECT COUNT(*) FROM dbo.Dim_Premises WHERE IsCurrent = 1)
UNION ALL
SELECT N'Договори',      (SELECT COUNT(*) FROM Rental.dbo.Contract), (SELECT COUNT(*) FROM dbo.Dim_Contract);

/* 7. Історія SCD2: приміщення, що мають кілька версій */
SELECT p.PremisesID, p.PremisesKey, p.MonthlyPrice, p.ValidFrom, p.ValidTo, p.IsCurrent
FROM dbo.Dim_Premises AS p
WHERE p.PremisesID IN (SELECT PremisesID FROM dbo.Dim_Premises GROUP BY PremisesID HAVING COUNT(*) > 1)
ORDER BY p.PremisesID, p.ValidFrom;
GO
