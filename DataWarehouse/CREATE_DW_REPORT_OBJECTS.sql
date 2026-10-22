USE [RentalDW];
GO

/* =====================================================================
   Об'єкти сховища для звітів SSRS (Rental_SSRS, джерело RentalDW).
   Аналітичні звіти беруть дані з куба, а документні звіти (02, 03, 03a) —
   з цих представлень і функцій. До OLTP-бази звіти не звертаються.
   Запуск: після CREATE_DW_TABLES.sql (можна повторно — CREATE OR ALTER).
   ===================================================================== */

/* Індекс для пошуку рахунків договору: зв'язок договір -> орендар / приміщення
   і рахунки договору в довідці орендаря */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Fact_Invoice_Contract'
               AND object_id = OBJECT_ID(N'dbo.Fact_Invoice'))
    CREATE NONCLUSTERED INDEX IX_Fact_Invoice_Contract
        ON dbo.Fact_Invoice (ContractKey, PeriodDateKey)
        INCLUDE (TenantKey, PremisesKey, TotalAmount, PaidAmount, DebtAmount);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Fact_Payment_Invoice'
               AND object_id = OBJECT_ID(N'dbo.Fact_Payment'))
    CREATE NONCLUSTERED INDEX IX_Fact_Payment_Invoice
        ON dbo.Fact_Payment (InvoiceID) INCLUDE (PaymentDateKey, Amount, DaysLate, PaymentTiming);
GO

/* ---------------------------------------------------------------------
   Договір з орендарем і приміщенням.
   Dim_Contract не має ключів орендаря й приміщення (це виміри факту),
   тому вони беруться з останнього рахунку договору — як в іменованому
   запиті Contract_Facts куба. Договори без жодного рахунку (ще не почалися)
   у представлення не потрапляють.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_ContractInfo
AS
SELECT
    c.ContractKey,
    c.ContractID,
    c.ContractNumber,
    c.SignDate,
    c.StartDate,
    c.EndDate,
    c.TerminationDate,
    c.EffectiveEndDate,
    c.IsTerminated,
    c.DurationMonths,
    c.MonthlyRent,
    c.Deposit,
    c.PaymentDay,
    l.TenantKey,
    l.PremisesKey,
    p.PremisesID
FROM dbo.Dim_Contract AS c
CROSS APPLY (SELECT TOP (1) f.TenantKey, f.PremisesKey
             FROM dbo.Fact_Invoice AS f
             WHERE f.ContractKey = c.ContractKey
             ORDER BY f.PeriodDateKey DESC) AS l
JOIN dbo.Dim_Premises AS p ON p.PremisesKey = l.PremisesKey;
GO

/* ---------------------------------------------------------------------
   Стан приміщень на дату (звіт 02).
   Приміщення береться у версії SCD2, чинній на цю дату (ValidFrom..ValidTo),
   тож площа, тип і ціна показуються такими, якими були на дату.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_PremisesStateOnDate (@Date DATE)
RETURNS TABLE
AS
RETURN
    WITH Active AS (
        -- договори, чинні на дату (одне приміщення — не більше одного договору на дату)
        SELECT c.ContractKey, c.ContractNumber, c.StartDate, c.EffectiveEndDate, c.MonthlyRent,
               l.TenantKey, l.PremisesKey
        FROM dbo.Dim_Contract AS c
        CROSS APPLY (SELECT TOP (1) f.TenantKey, f.PremisesKey
                     FROM dbo.Fact_Invoice AS f
                     WHERE f.ContractKey = c.ContractKey
                     ORDER BY f.PeriodDateKey DESC) AS l
        WHERE @Date BETWEEN c.StartDate AND c.EffectiveEndDate
    ),
    ActiveByPremises AS (
        SELECT ap.PremisesID, a.ContractNumber, a.StartDate, a.EffectiveEndDate, a.MonthlyRent,
               t.TenantID, t.Name AS TenantName, t.TaxCode,
               ROW_NUMBER() OVER (PARTITION BY ap.PremisesID ORDER BY a.StartDate DESC) AS rn
        FROM Active AS a
        JOIN dbo.Dim_Premises AS ap ON ap.PremisesKey = a.PremisesKey
        JOIN dbo.Dim_Tenant AS t    ON t.TenantKey = a.TenantKey
    )
    SELECT
        p.PremisesKey,
        p.PremisesID,
        p.City,
        p.Address,
        p.PremisesType,
        p.TypeGroup,
        p.Floor,
        p.RoomsCount,
        p.Area,
        p.MonthlyPrice,
        CASE WHEN a.PremisesID IS NULL THEN N'Вільне' ELSE N'Орендоване' END AS State,
        a.ContractNumber,
        a.TenantID,
        a.TenantName,
        a.TaxCode,
        a.StartDate,
        a.EffectiveEndDate AS RentEndDate,
        a.MonthlyRent
    FROM dbo.Dim_Premises AS p
    LEFT JOIN ActiveByPremises AS a ON a.PremisesID = p.PremisesID AND a.rn = 1
    WHERE @Date BETWEEN p.ValidFrom AND p.ValidTo;
GO

/* ---------------------------------------------------------------------
   Перевірка
   --------------------------------------------------------------------- */
SELECT State, COUNT(*) AS PremisesCount
FROM dbo.fn_PremisesStateOnDate(CAST(GETDATE() AS DATE))
GROUP BY State;

SELECT COUNT(*) AS ContractsWithInvoices FROM dbo.vw_ContractInfo;
GO
