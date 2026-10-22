USE [Rental];
GO

/* ==========================================================================
   ФУНКЦІЇ
   ========================================================================== */

/* Борг орендаря на дату = виставлено (IssueDate <= дата) − сплачено (PaymentDate <= дата) */
CREATE OR ALTER FUNCTION dbo.fn_TenantDebt
(
    @TenantID  INT,
    @AsOfDate  DATE
)
RETURNS DECIMAL(14,2)
AS
BEGIN
    DECLARE @Invoiced DECIMAL(14,2), @Paid DECIMAL(14,2);

    SELECT @Invoiced = SUM(i.TotalAmount)
    FROM dbo.Invoice AS i
    JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
    WHERE c.TenantID = @TenantID
      AND i.IssueDate <= @AsOfDate;

    SELECT @Paid = SUM(p.Amount)
    FROM dbo.Payment AS p
    JOIN dbo.Invoice AS i  ON i.InvoiceID  = p.InvoiceID
    JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
    WHERE c.TenantID = @TenantID
      AND p.PaymentDate <= @AsOfDate;

    RETURN ISNULL(@Invoiced, 0) - ISNULL(@Paid, 0);
END;
GO

/* Стан кожного приміщення на дату. Через тригер TR_Contract_Validate на одну дату
   припадає не більше одного договору, тож кожне приміщення дає рівно один рядок. */
CREATE OR ALTER FUNCTION dbo.fn_PremisesStateOnDate
(
    @Date DATE
)
RETURNS TABLE
AS
RETURN
    SELECT
        p.PremisesID,
        p.City,
        p.Address,
        pt.TypeID,
        pt.Name                                   AS PremisesType,
        p.Floor,
        p.RoomsCount,
        p.Area,
        p.MonthlyPrice,
        CASE WHEN c.ContractID IS NULL
             THEN N'Вільне' ELSE N'Орендоване' END AS State,
        c.ContractID,
        c.ContractNumber,
        t.TenantID,
        t.Name                                    AS TenantName,
        c.StartDate,
        COALESCE(c.TerminationDate, c.EndDate)    AS RentEndDate,
        c.MonthlyRent
    FROM dbo.Premises AS p
    JOIN dbo.PremisesType AS pt ON pt.TypeID = p.TypeID
    LEFT JOIN dbo.Contract AS c
           ON  c.PremisesID = p.PremisesID
           AND @Date BETWEEN c.StartDate AND COALESCE(c.TerminationDate, c.EndDate)
    LEFT JOIN dbo.Tenant AS t ON t.TenantID = c.TenantID;
GO

/* ==========================================================================
   БІЗНЕС-ОПЕРАЦІЇ
   ========================================================================== */

/* Оформлення договору.
   Якщо @MonthlyRent не передано — береться поточна ціна приміщення;
   якщо @Deposit не передано — депозит дорівнює місячній платі;
   якщо @ContractNumber не передано — формується як CN-<рік>-<ID>.
   Перетин з іншими договорами відсікає тригер TR_Contract_Validate. */
CREATE OR ALTER PROCEDURE dbo.sp_CreateContract
    @TenantID        INT,
    @PremisesID      INT,
    @StartDate       DATE,
    @EndDate         DATE,
    @SignDate        DATE          = NULL,
    @MonthlyRent     DECIMAL(12,2) = NULL,
    @Deposit         DECIMAL(12,2) = NULL,
    @PaymentDay      TINYINT       = 10,
    @ContractNumber  VARCHAR(20)   = NULL,
    @ContractID      INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SignDate = ISNULL(@SignDate, CAST(GETDATE() AS DATE));

    IF @MonthlyRent IS NULL
        SELECT @MonthlyRent = MonthlyPrice
        FROM dbo.Premises
        WHERE PremisesID = @PremisesID;

    IF @MonthlyRent IS NULL
    BEGIN
        ;THROW 50030, N'Приміщення не знайдено.', 1;
    END;

    SET @Deposit = ISNULL(@Deposit, @MonthlyRent);

    BEGIN TRANSACTION;

        INSERT INTO dbo.Contract
            (ContractNumber, TenantID, PremisesID, SignDate, StartDate, EndDate,
             TerminationDate, MonthlyRent, Deposit, PaymentDay)
        VALUES
            (ISNULL(@ContractNumber,
                    CONCAT('TMP-', LEFT(REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''), 16))),
             @TenantID, @PremisesID, @SignDate, @StartDate, @EndDate,
             NULL, @MonthlyRent, @Deposit, @PaymentDay);

        SET @ContractID = SCOPE_IDENTITY();

        IF @ContractNumber IS NULL
            UPDATE dbo.Contract
            SET ContractNumber = CONCAT('CN-', YEAR(@SignDate), '-',
                                        RIGHT(CONCAT('0000000', @ContractID), 7))
            WHERE ContractID = @ContractID;

    COMMIT TRANSACTION;

    SELECT ContractID, ContractNumber
    FROM dbo.Contract
    WHERE ContractID = @ContractID;
END;
GO

/* Дострокове розірвання договору. @TerminationDate — останній день оренди.
   Якщо вже є рахунки за місяці після розірвання, тригер не дасть змінити дату. */
CREATE OR ALTER PROCEDURE dbo.sp_TerminateContract
    @ContractID       INT,
    @TerminationDate  DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @TerminationDate = ISNULL(@TerminationDate, CAST(GETDATE() AS DATE));

    IF NOT EXISTS (SELECT 1 FROM dbo.Contract WHERE ContractID = @ContractID)
    BEGIN
        ;THROW 50031, N'Договір не знайдено.', 1;
    END;

    IF EXISTS (SELECT 1 FROM dbo.Contract
               WHERE ContractID = @ContractID AND TerminationDate IS NOT NULL)
    BEGIN
        ;THROW 50032, N'Договір уже розірвано.', 1;
    END;

    UPDATE dbo.Contract
    SET TerminationDate = @TerminationDate
    WHERE ContractID = @ContractID;
END;
GO

/* Виставлення рахунків за місяць усім договорам, що діяли в цьому місяці
   хоча б один день. Неповний місяць оплачується пропорційно дням оренди.
   Комунальні = площа × тариф за м² (пропорційно дням).
   Термін оплати — PaymentDay місяця, але не раніше дати початку оренди.
   Повторний запуск за той самий місяць дублікатів не створює. */
CREATE OR ALTER PROCEDURE dbo.sp_GenerateMonthlyInvoices
    @PeriodMonth    DATE,
    @UtilitiesRate  DECIMAL(8,2) = 25.00   -- грн за м² на місяць
AS
BEGIN
    SET NOCOUNT ON;

    SET @PeriodMonth = DATEFROMPARTS(YEAR(@PeriodMonth), MONTH(@PeriodMonth), 1);

    DECLARE @MonthEnd     DATE = EOMONTH(@PeriodMonth);
    DECLARE @DaysInMonth  INT  = DAY(EOMONTH(@PeriodMonth));

    INSERT INTO dbo.Invoice
        (InvoiceNumber, ContractID, StatusID, PeriodMonth, IssueDate, DueDate,
         RentAmount, UtilitiesAmount, PenaltyAmount)
    SELECT
        CONCAT('INV-', FORMAT(@PeriodMonth, 'yyyyMM'), '-', c.ContractID),
        c.ContractID,
        1,
        @PeriodMonth,
        GREATEST(@PeriodMonth, c.SignDate),                          -- не раніше підписання договору
        GREATEST(DATEFROMPARTS(YEAR(@PeriodMonth), MONTH(@PeriodMonth), c.PaymentDay),
                 c.StartDate, c.SignDate, @PeriodMonth),             -- не раніше початку оренди
        ROUND(c.MonthlyRent * d.ActiveDays / @DaysInMonth, 2),
        ROUND(p.Area * @UtilitiesRate * d.ActiveDays / @DaysInMonth, 2),
        0
    FROM dbo.Contract AS c
    JOIN dbo.Premises AS p ON p.PremisesID = c.PremisesID
    CROSS APPLY (
        SELECT DATEDIFF(DAY,
                   CASE WHEN c.StartDate > @PeriodMonth THEN c.StartDate ELSE @PeriodMonth END,
                   CASE WHEN COALESCE(c.TerminationDate, c.EndDate) < @MonthEnd
                        THEN COALESCE(c.TerminationDate, c.EndDate) ELSE @MonthEnd END
               ) + 1 AS ActiveDays
    ) AS d
    WHERE c.StartDate <= @MonthEnd
      AND COALESCE(c.TerminationDate, c.EndDate) >= @PeriodMonth
      AND NOT EXISTS (SELECT 1
                      FROM dbo.Invoice AS i
                      WHERE i.ContractID = c.ContractID
                        AND i.PeriodMonth = @PeriodMonth);

    SELECT @@ROWCOUNT AS InvoicesCreated;
END;
GO

/* Реєстрація платежу. Перевірки (переплата, дата) і перерахунок статусу
   виконує тригер TR_Payment_RecalcInvoice. */
CREATE OR ALTER PROCEDURE dbo.sp_RegisterPayment
    @InvoiceID       INT,
    @Amount          DECIMAL(12,2),
    @PaymentDate     DATE        = NULL,
    @DocumentNumber  VARCHAR(30) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @PaymentDate = ISNULL(@PaymentDate, CAST(GETDATE() AS DATE));

    INSERT INTO dbo.Payment (InvoiceID, PaymentDate, Amount, DocumentNumber)
    VALUES (@InvoiceID, @PaymentDate, @Amount, @DocumentNumber);

    SELECT i.InvoiceID, i.InvoiceNumber, i.TotalAmount,
           s.Paid, i.TotalAmount - s.Paid AS Remaining,
           st.Name AS InvoiceStatus
    FROM dbo.Invoice AS i
    JOIN dbo.InvoiceStatus AS st ON st.StatusID = i.StatusID
    CROSS APPLY (SELECT SUM(p.Amount) AS Paid
                 FROM dbo.Payment AS p
                 WHERE p.InvoiceID = i.InvoiceID) AS s
    WHERE i.InvoiceID = @InvoiceID;
END;
GO

/* Перерахунок статусів усіх рахунків на дату (за замовчуванням — сьогодні).
   Потрібен щодня (рахунки стають простроченими з плином часу) і після
   масового завантаження даних із вимкненими тригерами. */
CREATE OR ALTER PROCEDURE dbo.sp_RefreshInvoiceStatuses
    @AsOfDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @AsOfDate = ISNULL(@AsOfDate, CAST(GETDATE() AS DATE));

    UPDATE inv
    SET StatusID = x.NewStatusID
    FROM dbo.Invoice AS inv
    OUTER APPLY (SELECT SUM(p.Amount) AS Paid
                 FROM dbo.Payment AS p
                 WHERE p.InvoiceID = inv.InvoiceID) AS s
    CROSS APPLY (SELECT dbo.fn_CalcInvoiceStatus(inv.TotalAmount, ISNULL(s.Paid, 0),
                                                 inv.DueDate, @AsOfDate) AS NewStatusID) AS x
    WHERE inv.StatusID <> x.NewStatusID;

    SELECT @@ROWCOUNT AS StatusesChanged;
END;
GO

/* Нарахування пені за кожен день прострочки:
   пеня = непогашена основна сума (оренда + комунальні − сплачено) × ставка × днів прострочки,
   але не більше ніж за @MaxDays днів.
   Пеня лише зростає, зменшити її цією процедурою не можна. */
CREATE OR ALTER PROCEDURE dbo.sp_ApplyPenalties
    @AsOfDate   DATE         = NULL,
    @DailyRate  DECIMAL(6,4) = 0.0010,  -- 0,1 % за день
    @MaxDays    INT          = 180
AS
BEGIN
    SET NOCOUNT ON;

    SET @AsOfDate = ISNULL(@AsOfDate, CAST(GETDATE() AS DATE));

    UPDATE inv
    SET PenaltyAmount = x.NewPenalty
    FROM dbo.Invoice AS inv
    OUTER APPLY (SELECT SUM(p.Amount) AS Paid
                 FROM dbo.Payment AS p
                 WHERE p.InvoiceID = inv.InvoiceID) AS s
    CROSS APPLY (SELECT ROUND((inv.RentAmount + inv.UtilitiesAmount - ISNULL(s.Paid, 0))
                              * @DailyRate
                              * LEAST(DATEDIFF(DAY, inv.DueDate, @AsOfDate), @MaxDays), 2) AS NewPenalty) AS x
    WHERE inv.DueDate < @AsOfDate
      AND inv.RentAmount + inv.UtilitiesAmount > ISNULL(s.Paid, 0)
      AND x.NewPenalty > inv.PenaltyAmount;

    SELECT @@ROWCOUNT AS InvoicesWithPenalty;
END;
GO

/* ==========================================================================
   ЗВІТИ
   ========================================================================== */

/* 1. Список орендарів з інформацією про оренду та борги на дату */
CREATE OR ALTER PROCEDURE dbo.sp_GetTenantsWithDebts
    @AsOfDate     DATE = NULL,
    @OnlyDebtors  BIT  = 0
AS
BEGIN
    SET NOCOUNT ON;

    SET @AsOfDate = ISNULL(@AsOfDate, CAST(GETDATE() AS DATE));

    WITH Inv AS (
        SELECT c.TenantID, SUM(i.TotalAmount) AS Invoiced
        FROM dbo.Invoice AS i
        JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
        WHERE i.IssueDate <= @AsOfDate
        GROUP BY c.TenantID
    ),
    Pay AS (
        SELECT c.TenantID, SUM(p.Amount) AS Paid
        FROM dbo.Payment AS p
        JOIN dbo.Invoice  AS i ON i.InvoiceID  = p.InvoiceID
        JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
        WHERE p.PaymentDate <= @AsOfDate
        GROUP BY c.TenantID
    ),
    Rent AS (
        SELECT TenantID,
               COUNT(*) AS ContractsTotal,
               SUM(CASE WHEN @AsOfDate BETWEEN StartDate AND COALESCE(TerminationDate, EndDate)
                        THEN 1 ELSE 0 END) AS ContractsActive
        FROM dbo.Contract
        WHERE StartDate <= @AsOfDate
        GROUP BY TenantID
    )
    SELECT
        t.TenantID,
        t.Name,
        tt.Name                                   AS TenantType,
        t.TaxCode,
        t.Phone,
        t.Email,
        r.ContractsTotal,
        r.ContractsActive,
        ISNULL(inv.Invoiced, 0)                   AS Invoiced,
        ISNULL(pay.Paid, 0)                       AS Paid,
        ISNULL(inv.Invoiced, 0) - ISNULL(pay.Paid, 0) AS Debt
    FROM dbo.Tenant AS t
    JOIN dbo.TenantType AS tt ON tt.TenantTypeID = t.TenantTypeID
    JOIN Rent AS r            ON r.TenantID = t.TenantID
    LEFT JOIN Inv AS inv      ON inv.TenantID = t.TenantID
    LEFT JOIN Pay AS pay      ON pay.TenantID = t.TenantID
    WHERE @OnlyDebtors = 0
       OR ISNULL(inv.Invoiced, 0) - ISNULL(pay.Paid, 0) > 0
    ORDER BY Debt DESC, t.Name;
END;
GO

/* 2. Стан приміщень на певну дату */
CREATE OR ALTER PROCEDURE dbo.sp_GetPremisesStateOnDate
    @Date    DATE         = NULL,
    @City    NVARCHAR(50) = NULL,
    @TypeID  INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @Date = ISNULL(@Date, CAST(GETDATE() AS DATE));

    SELECT *
    FROM dbo.fn_PremisesStateOnDate(@Date)
    WHERE (@City   IS NULL OR City   = @City)
      AND (@TypeID IS NULL OR TypeID = @TypeID)
    ORDER BY City, Address;
END;
GO

/* 3. Довідка орендаря про історію оренди та платежів (рядок = рахунок) */
CREATE OR ALTER PROCEDURE dbo.sp_GetTenantHistory
    @TenantID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.Name                                    AS TenantName,
        t.TaxCode,
        c.ContractNumber,
        p.City,
        p.Address,
        pt.Name                                   AS PremisesType,
        c.StartDate,
        COALESCE(c.TerminationDate, c.EndDate)    AS RentEndDate,
        CASE WHEN c.TerminationDate IS NOT NULL THEN N'Розірвано'
             WHEN c.EndDate < CAST(GETDATE() AS DATE) THEN N'Завершено'
             WHEN c.StartDate > CAST(GETDATE() AS DATE) THEN N'Ще не почався'
             ELSE N'Діє' END                      AS ContractState,
        c.MonthlyRent,
        i.InvoiceNumber,
        i.PeriodMonth,
        i.IssueDate,
        i.DueDate,
        i.TotalAmount,
        ISNULL(s.Paid, 0)                         AS Paid,
        i.TotalAmount - ISNULL(s.Paid, 0)         AS Debt,
        s.LastPaymentDate,
        st.Name                                   AS InvoiceStatus
    FROM dbo.Contract AS c
    JOIN dbo.Tenant AS t        ON t.TenantID = c.TenantID
    JOIN dbo.Premises AS p      ON p.PremisesID = c.PremisesID
    JOIN dbo.PremisesType AS pt ON pt.TypeID = p.TypeID
    LEFT JOIN dbo.Invoice AS i        ON i.ContractID = c.ContractID
    LEFT JOIN dbo.InvoiceStatus AS st ON st.StatusID = i.StatusID
    OUTER APPLY (SELECT SUM(pay.Amount)      AS Paid,
                        MAX(pay.PaymentDate) AS LastPaymentDate
                 FROM dbo.Payment AS pay
                 WHERE pay.InvoiceID = i.InvoiceID) AS s
    WHERE c.TenantID = @TenantID
    ORDER BY c.StartDate, i.PeriodMonth;
END;
GO

/* 4. Аналіз завантаженості приміщень за період:
   відсоток днів, коли приміщення було в оренді */
CREATE OR ALTER PROCEDURE dbo.sp_GetPremisesOccupancy
    @DateFrom  DATE,
    @DateTo    DATE,
    @City      NVARCHAR(50) = NULL,
    @TypeID    INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @DateTo < @DateFrom
    BEGIN
        ;THROW 50040, N'Кінець періоду раніший за початок.', 1;
    END;

    DECLARE @TotalDays INT = DATEDIFF(DAY, @DateFrom, @DateTo) + 1;

    SELECT
        p.PremisesID,
        p.City,
        p.Address,
        pt.Name                                         AS PremisesType,
        p.Floor,
        p.Area,
        COUNT(o.ContractID)                             AS ContractsCount,
        ISNULL(SUM(o.RentedDays), 0)                    AS RentedDays,
        @TotalDays                                      AS TotalDays,
        CAST(100.0 * ISNULL(SUM(o.RentedDays), 0) / @TotalDays AS DECIMAL(5,2)) AS OccupancyPct
    FROM dbo.Premises AS p
    JOIN dbo.PremisesType AS pt ON pt.TypeID = p.TypeID
    LEFT JOIN (
        SELECT
            c.PremisesID,
            c.ContractID,
            DATEDIFF(DAY,
                CASE WHEN c.StartDate > @DateFrom THEN c.StartDate ELSE @DateFrom END,
                CASE WHEN COALESCE(c.TerminationDate, c.EndDate) < @DateTo
                     THEN COALESCE(c.TerminationDate, c.EndDate) ELSE @DateTo END
            ) + 1 AS RentedDays
        FROM dbo.Contract AS c
        WHERE c.StartDate <= @DateTo
          AND COALESCE(c.TerminationDate, c.EndDate) >= @DateFrom
    ) AS o ON o.PremisesID = p.PremisesID
    WHERE (@City   IS NULL OR p.City   = @City)
      AND (@TypeID IS NULL OR p.TypeID = @TypeID)
    GROUP BY p.PremisesID, p.City, p.Address, pt.Name, p.Floor, p.Area
    ORDER BY OccupancyPct DESC, p.City, p.Address;
END;
GO

/* 5. Фінансовий звіт по орендарях за період:
   нараховано та сплачено за період, борг на кінець періоду */
CREATE OR ALTER PROCEDURE dbo.sp_GetTenantFinancialReport
    @DateFrom      DATE,
    @DateTo        DATE,
    @TenantTypeID  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @DateTo < @DateFrom
    BEGIN
        ;THROW 50041, N'Кінець періоду раніший за початок.', 1;
    END;

    WITH InvPeriod AS (
        SELECT c.TenantID,
               COUNT(*)                AS InvoicesCount,
               SUM(i.RentAmount)       AS RentAmount,
               SUM(i.UtilitiesAmount)  AS UtilitiesAmount,
               SUM(i.PenaltyAmount)    AS PenaltyAmount,
               SUM(i.TotalAmount)      AS Invoiced,
               SUM(CASE WHEN i.StatusID = 4 THEN 1 ELSE 0 END) AS OverdueInvoices
        FROM dbo.Invoice AS i
        JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
        WHERE i.IssueDate BETWEEN @DateFrom AND @DateTo
        GROUP BY c.TenantID
    ),
    PayPeriod AS (
        SELECT c.TenantID,
               COUNT(*)       AS PaymentsCount,
               SUM(p.Amount)  AS Paid
        FROM dbo.Payment AS p
        JOIN dbo.Invoice  AS i ON i.InvoiceID  = p.InvoiceID
        JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
        WHERE p.PaymentDate BETWEEN @DateFrom AND @DateTo
        GROUP BY c.TenantID
    ),
    InvToDate AS (
        SELECT c.TenantID, SUM(i.TotalAmount) AS Invoiced
        FROM dbo.Invoice AS i
        JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
        WHERE i.IssueDate <= @DateTo
        GROUP BY c.TenantID
    ),
    PayToDate AS (
        SELECT c.TenantID, SUM(p.Amount) AS Paid
        FROM dbo.Payment AS p
        JOIN dbo.Invoice  AS i ON i.InvoiceID  = p.InvoiceID
        JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
        WHERE p.PaymentDate <= @DateTo
        GROUP BY c.TenantID
    )
    SELECT
        t.TenantID,
        t.Name,
        tt.Name                                      AS TenantType,
        t.TaxCode,
        ISNULL(ip.InvoicesCount, 0)                  AS InvoicesCount,
        ISNULL(ip.RentAmount, 0)                     AS RentAmount,
        ISNULL(ip.UtilitiesAmount, 0)                AS UtilitiesAmount,
        ISNULL(ip.PenaltyAmount, 0)                  AS PenaltyAmount,
        ISNULL(ip.Invoiced, 0)                       AS Invoiced,
        ISNULL(pp.PaymentsCount, 0)                  AS PaymentsCount,
        ISNULL(pp.Paid, 0)                           AS Paid,
        ISNULL(ip.OverdueInvoices, 0)                AS OverdueInvoices,
        ISNULL(itd.Invoiced, 0) - ISNULL(ptd.Paid, 0) AS DebtAtPeriodEnd
    FROM dbo.Tenant AS t
    JOIN dbo.TenantType AS tt  ON tt.TenantTypeID = t.TenantTypeID
    LEFT JOIN InvPeriod AS ip  ON ip.TenantID  = t.TenantID
    LEFT JOIN PayPeriod AS pp  ON pp.TenantID  = t.TenantID
    LEFT JOIN InvToDate AS itd ON itd.TenantID = t.TenantID
    LEFT JOIN PayToDate AS ptd ON ptd.TenantID = t.TenantID
    WHERE (ip.TenantID IS NOT NULL OR pp.TenantID IS NOT NULL)
      AND (@TenantTypeID IS NULL OR t.TenantTypeID = @TenantTypeID)
    ORDER BY ISNULL(ip.Invoiced, 0) DESC, t.Name;
END;
GO

PRINT N'Функції та процедури створено.';
GO
