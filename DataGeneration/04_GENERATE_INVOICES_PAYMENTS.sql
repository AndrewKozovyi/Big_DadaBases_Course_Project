USE [Rental];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Rows INT;

IF EXISTS (SELECT 1 FROM dbo.Invoice) OR EXISTS (SELECT 1 FROM dbo.Payment)
BEGIN
    ;THROW 51006, N'Таблиці Invoice / Payment не порожні. Спочатку виконайте 00_CLEAR_DATA.sql.', 1;
END;
IF NOT EXISTS (SELECT 1 FROM dbo.Contract)
BEGIN
    ;THROW 51007, N'Спочатку згенеруйте договори (03).', 1;
END;

DECLARE @HistoryEnd      DATE         = '2026-10-22';  -- «сьогодні» для згенерованих даних
DECLARE @PenaltyRate     DECIMAL(6,4) = 0.0010;        -- пеня 0,1 % за день прострочки
DECLARE @MaxPenaltyDays  INT          = 180;           -- пеня нараховується не більше ніж за 180 днів
DECLARE @RiskyTenantPct  INT          = 10;            -- частка «проблемних» орендарів, %

/* =====================================================================
   1. «Проблемні» орендарі: часто платять із запізненням або не платять зовсім.
      Так борги зосереджені в окремих орендарів, як у реальності.
   ===================================================================== */
SELECT
    TenantID,
    CASE WHEN ABS(CHECKSUM(NEWID()) % 1000000) % 100 < @RiskyTenantPct THEN 1 ELSE 0 END AS IsRisky
INTO #Risk
FROM dbo.Tenant;

/* =====================================================================
   2. Рахунок за кожен місяць, у якому договір діяв хоча б один день
      (не пізніше поточного місяця @HistoryEnd)
   ===================================================================== */
WITH M AS (
    SELECT TOP (13) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects
),
C AS (
    SELECT
        c.ContractID,
        c.TenantID,
        c.SignDate,
        c.StartDate,
        COALESCE(c.TerminationDate, c.EndDate)                  AS EffEnd,
        c.MonthlyRent,
        c.PaymentDay,
        p.Area,
        DATEFROMPARTS(YEAR(c.StartDate), MONTH(c.StartDate), 1) AS StartMonth
    FROM dbo.Contract AS c
    JOIN dbo.Premises AS p ON p.PremisesID = c.PremisesID
)
SELECT
    C.*,
    DATEADD(MONTH, M.i, C.StartMonth) AS PeriodMonth
INTO #Base
FROM C
JOIN M ON DATEADD(MONTH, M.i, C.StartMonth) <= C.EffEnd
WHERE DATEADD(MONTH, M.i, C.StartMonth) <= @HistoryEnd;

/* =====================================================================
   3. Суми та дати рахунку
      Оренда: пропорційно дням оренди в місяці.
      Комунальні: площа × тариф року (опалювальний сезон листопад–березень × 1,5).
      Дата рахунку: 1-ше число, але не раніше підписання договору.
      Термін оплати: PaymentDay місяця, але не раніше початку оренди.
   ===================================================================== */
SELECT
    b.ContractID,
    b.TenantID,
    b.PeriodMonth,
    GREATEST(b.PeriodMonth, b.SignDate) AS IssueDate,
    GREATEST(DATEFROMPARTS(YEAR(b.PeriodMonth), MONTH(b.PeriodMonth), b.PaymentDay),
             b.StartDate, b.SignDate, b.PeriodMonth) AS DueDate,
    CAST(ROUND(b.MonthlyRent * d.ActiveDays / d.DaysInMonth, 2) AS DECIMAL(12,2))      AS RentAmount,
    CAST(ROUND(b.Area * t.Tariff * d.ActiveDays / d.DaysInMonth, 2) AS DECIMAL(12,2))  AS UtilitiesAmount
INTO #Amounts
FROM #Base AS b
CROSS APPLY (
    SELECT DATEDIFF(DAY, GREATEST(b.StartDate, b.PeriodMonth),
                         LEAST(b.EffEnd, EOMONTH(b.PeriodMonth))) + 1 AS ActiveDays,
           DAY(EOMONTH(b.PeriodMonth)) AS DaysInMonth
) AS d
CROSS APPLY (
    SELECT CAST(CASE YEAR(b.PeriodMonth)
                    WHEN 2021 THEN 16 WHEN 2022 THEN 18 WHEN 2023 THEN 22
                    WHEN 2024 THEN 25 WHEN 2025 THEN 28 ELSE 32 END   -- грн за м² на місяць
                * CASE WHEN MONTH(b.PeriodMonth) IN (11, 12, 1, 2, 3) THEN 1.5 ELSE 1.0 END
           AS DECIMAL(8,2)) AS Tariff
) AS t
WHERE GREATEST(b.PeriodMonth, b.SignDate) <= @HistoryEnd;

/* =====================================================================
   4. Сценарій оплати кожного рахунку
      Термін оплати ще не настав:  F — оплачено наперед (45 %), P — частина наперед (10 %),
                                   N — ще не оплачено (45 %)
      Звичайний орендар:  F — повністю одним платежем (90 %, з них 20 % із запізненням),
                          S — двома частинами (7 %), P — частково (1 %), U — не оплачено (2 %)
      Проблемний орендар: F — повністю, у половині випадків із запізненням (45 %),
                          P — частково (15 %), U — не оплачено (40 %)
   ===================================================================== */
SELECT
    a.*,
    r.IsRisky,
    a.RentAmount + a.UtilitiesAmount AS BaseAmount,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100 AS rScenario,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100 AS rLate,
    ABS(CHECKSUM(NEWID()) % 1000000)       AS rDays1,
    ABS(CHECKSUM(NEWID()) % 1000000)       AS rDays2,
    ABS(CHECKSUM(NEWID()) % 1000000) / 1000000.0 AS rShare
INTO #Rnd
FROM #Amounts AS a
JOIN #Risk AS r ON r.TenantID = a.TenantID;

SELECT
    x.*,
    CASE
        WHEN x.DueDate >= @HistoryEnd THEN CASE WHEN x.rScenario < 45 THEN 'F'
                                                WHEN x.rScenario < 55 THEN 'P'
                                                ELSE 'N' END
        WHEN x.IsRisky = 1 THEN CASE WHEN x.rScenario < 40 THEN 'U'
                                     WHEN x.rScenario < 55 THEN 'P'
                                     ELSE 'F' END
        ELSE CASE WHEN x.rScenario < 2  THEN 'U'
                  WHEN x.rScenario < 3  THEN 'P'
                  WHEN x.rScenario < 10 THEN 'S'
                  ELSE 'F' END
    END AS Scenario,
    CASE WHEN x.rLate < CASE WHEN x.IsRisky = 1 THEN 50 ELSE 20 END THEN 1 ELSE 0 END AS IsLate
INTO #Scen0
FROM #Rnd AS x;

-- Дати платежів
SELECT
    s.*,
    CASE
        WHEN s.Scenario IN ('F', 'P') AND s.DueDate >= @HistoryEnd          -- оплата наперед
            THEN DATEADD(DAY, s.rDays1 % (DATEDIFF(DAY, s.IssueDate, @HistoryEnd) + 1), s.IssueDate)
        WHEN s.Scenario = 'F' AND s.IsLate = 1                              -- із запізненням
            THEN DATEADD(DAY, 1 + s.rDays1 % CASE WHEN s.IsRisky = 1 THEN 60 ELSE 30 END, s.DueDate)
        WHEN s.Scenario IN ('F', 'S', 'P')                                  -- вчасно: 0–5 днів до терміну
            THEN GREATEST(s.IssueDate, DATEADD(DAY, -(s.rDays1 % 6), s.DueDate))
    END AS Pay1Date,
    CASE WHEN s.Scenario = 'S' THEN DATEADD(DAY, 1 + s.rDays2 % 20, s.DueDate) END AS Pay2Date
INTO #Scen1
FROM #Scen0 AS s;

-- Платіж, дата якого ще не настала, вважається не зробленим:
-- F із запізненням → U (борг), S без другої частини → P (часткова оплата)
SELECT
    s.ContractID, s.PeriodMonth, s.IssueDate, s.DueDate,
    s.RentAmount, s.UtilitiesAmount, s.BaseAmount, s.rShare,
    CASE WHEN s.Scenario = 'F' AND s.Pay1Date > @HistoryEnd THEN 'U'
         WHEN s.Scenario = 'S' AND s.Pay2Date > @HistoryEnd THEN 'P'
         ELSE s.Scenario END AS Scenario,
    CASE WHEN s.Scenario = 'S' AND s.Pay2Date > @HistoryEnd THEN 1 ELSE 0 END AS FromSplit,
    CASE WHEN s.Scenario = 'F' AND s.Pay1Date > @HistoryEnd THEN NULL ELSE s.Pay1Date END AS Pay1Date,
    CASE WHEN s.Pay2Date > @HistoryEnd THEN NULL ELSE s.Pay2Date END AS Pay2Date
INTO #Scen
FROM #Scen1 AS s;

/* =====================================================================
   5. Пеня та суми платежів
      F: пеня за дні запізнення; платіж = основна сума + пеня
      S: половина вчасно, решта із запізненням + пеня на решту
      P: оплачено 30–80 % (або половину, якщо друга частина S не настала);
         пеня на залишок за дні прострочки (не більше @MaxPenaltyDays; 0, якщо термін не настав)
      U: пеня на всю суму за дні прострочки (не більше @MaxPenaltyDays)
   ===================================================================== */
SELECT
    s.*,
    p1.FirstPart,
    CAST(CASE s.Scenario
        WHEN 'F' THEN ROUND(s.BaseAmount * @PenaltyRate
                            * GREATEST(0, DATEDIFF(DAY, s.DueDate, s.Pay1Date)), 2)
        WHEN 'S' THEN ROUND((s.BaseAmount - p1.FirstPart) * @PenaltyRate
                            * DATEDIFF(DAY, s.DueDate, s.Pay2Date), 2)
        WHEN 'P' THEN ROUND((s.BaseAmount - p1.FirstPart) * @PenaltyRate
                            * GREATEST(0, LEAST(DATEDIFF(DAY, s.DueDate, @HistoryEnd), @MaxPenaltyDays)), 2)
        WHEN 'U' THEN ROUND(s.BaseAmount * @PenaltyRate
                            * LEAST(DATEDIFF(DAY, s.DueDate, @HistoryEnd), @MaxPenaltyDays), 2)
        ELSE 0
    END AS DECIMAL(12,2)) AS PenaltyAmount
INTO #Final0
FROM #Scen AS s
CROSS APPLY (
    SELECT CAST(CASE
               WHEN s.Scenario = 'S' OR s.FromSplit = 1 THEN ROUND(s.BaseAmount * 0.5, 2)
               WHEN s.Scenario = 'P' THEN ROUND(s.BaseAmount * (0.30 + s.rShare * 0.50), 2)
           END AS DECIMAL(12,2)) AS FirstPart
) AS p1;

SELECT
    f.*,
    CASE f.Scenario
        WHEN 'F' THEN f.BaseAmount + f.PenaltyAmount
        WHEN 'S' THEN f.FirstPart
        WHEN 'P' THEN f.FirstPart
    END AS Pay1Amount,
    CASE WHEN f.Scenario = 'S'
         THEN f.BaseAmount - f.FirstPart + f.PenaltyAmount
    END AS Pay2Amount
INTO #Final
FROM #Final0 AS f;

/* =====================================================================
   6. Вставка рахунків.
      Тригер TR_Invoice_Validate перевіряє, що рахунок у межах дії договору,
      і виставляє початковий статус.
   ===================================================================== */
INSERT INTO dbo.Invoice
    (InvoiceNumber, ContractID, StatusID, PeriodMonth, IssueDate, DueDate,
     RentAmount, UtilitiesAmount, PenaltyAmount)
SELECT
    CONCAT('INV-', CONVERT(CHAR(6), PeriodMonth, 112), '-', ContractID),
    ContractID,
    1,
    PeriodMonth,
    IssueDate,
    DueDate,
    RentAmount,
    UtilitiesAmount,
    PenaltyAmount
FROM #Final
ORDER BY PeriodMonth, ContractID;

SET @Rows = @@ROWCOUNT;
RAISERROR(N'Invoice: %d', 0, 1, @Rows) WITH NOWAIT;

/* =====================================================================
   7. Вставка платежів.
      Тригер TR_Payment_RecalcInvoice перевіряє відсутність переплати
      та дату платежу і перераховує статуси рахунків.
   ===================================================================== */
WITH P AS (
    SELECT
        i.InvoiceID,
        x.PayDate,
        x.Amount,
        ROW_NUMBER() OVER (ORDER BY x.PayDate, i.InvoiceID, x.PayNo) AS DocNo
    FROM #Final AS f
    JOIN dbo.Invoice AS i
      ON i.ContractID = f.ContractID AND i.PeriodMonth = f.PeriodMonth
    CROSS APPLY (VALUES (1, f.Pay1Date, f.Pay1Amount),
                        (2, f.Pay2Date, f.Pay2Amount)) AS x (PayNo, PayDate, Amount)
    WHERE x.Amount IS NOT NULL
)
INSERT INTO dbo.Payment (InvoiceID, PaymentDate, Amount, DocumentNumber)
SELECT
    InvoiceID,
    PayDate,
    Amount,
    CONCAT('PD-', CONVERT(CHAR(8), PayDate, 112), '-', RIGHT(CONCAT('000000', DocNo), 6))
FROM P
ORDER BY DocNo;

SET @Rows = @@ROWCOUNT;
RAISERROR(N'Payment: %d', 0, 1, @Rows) WITH NOWAIT;

DROP TABLE #Risk, #Base, #Amounts, #Rnd, #Scen0, #Scen1, #Scen, #Final0, #Final;
GO
