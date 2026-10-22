USE [RentalDW];
GO

/* =====================================================================
   1. Початок запуску ETL
      • визначає фактичний режим: INCREMENTAL можливий лише після успішного запуску,
        інакше виконується FULL;
      • створює запис в ETL_Audit і повертає RunID та watermark-и
        (останні завантажені InvoiceID / PaymentID; для FULL — 0);
      • очищає staging-таблиці SCD.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_Start
    @RequestedMode NVARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Mode NVARCHAR(20) = UPPER(LTRIM(RTRIM(ISNULL(@RequestedMode, N'FULL'))));
    DECLARE @LastInvoiceID INT = 0, @LastPaymentID INT = 0, @Message NVARCHAR(4000) = NULL;

    IF @Mode NOT IN (N'FULL', N'INCREMENTAL')
    BEGIN
        SET @Message = CONCAT(N'Невідомий режим «', @RequestedMode, N'», виконується FULL.');
        SET @Mode = N'FULL';
    END;

    IF @Mode = N'INCREMENTAL'
    BEGIN
        SELECT TOP (1)
            @LastInvoiceID = ISNULL(LastInvoiceID, 0),
            @LastPaymentID = ISNULL(LastPaymentID, 0)
        FROM dbo.ETL_Audit
        WHERE Status IN (N'Success', N'Warning')
        ORDER BY RunID DESC;

        IF @@ROWCOUNT = 0
        BEGIN
            SET @Message = N'Немає жодного успішного запуску — замість INCREMENTAL виконується FULL.';
            SET @Mode = N'FULL';
        END;
    END;

    INSERT INTO dbo.ETL_Audit (RequestedMode, LoadMode, Status, Message)
    VALUES (ISNULL(@RequestedMode, N''), @Mode, N'Running', @Message);

    DECLARE @RunID INT = SCOPE_IDENTITY();

    TRUNCATE TABLE dbo.Stage_Tenant;
    TRUNCATE TABLE dbo.Stage_Premises;
    TRUNCATE TABLE dbo.Stage_Contract;

    SELECT
        @RunID          AS RunID,
        @Mode           AS LoadMode,
        @LastInvoiceID  AS LastInvoiceID,
        @LastPaymentID  AS LastPaymentID;
END;
GO

/* =====================================================================
   2. Підготовка таблиць фактів перед завантаженням
      FULL:        факти очищаються повністю.
      INCREMENTAL: з Fact_Invoice видаляються незакриті рахунки та рахунки з новими
                   платежами — у них могли змінитися статус, пеня або сплачена сума;
                   ETL завантажить їх заново разом з новими рахунками.
                   Fact_Payment не чіпаємо: платежі лише додаються.
      Fact_Occupancy — знімок, щоразу перебудовується повністю.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_PrepareFacts
    @RunID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Mode NVARCHAR(20) = (SELECT LoadMode FROM dbo.ETL_Audit WHERE RunID = @RunID);

    IF @Mode = N'FULL'
    BEGIN
        TRUNCATE TABLE dbo.Fact_Invoice;
        TRUNCATE TABLE dbo.Fact_Payment;
    END
    ELSE
    BEGIN
        -- Ті самі умови, за якими пакет повторно читає рахунки з OLTP (змінна SqlFactInvoice):
        -- незакриті у сховищі, не оплачені в OLTP або з новими платежами після останнього запуску.
        DECLARE @LastPaymentID INT = ISNULL((SELECT TOP (1) LastPaymentID
                                             FROM dbo.ETL_Audit
                                             WHERE Status IN (N'Success', N'Warning') AND RunID < @RunID
                                             ORDER BY RunID DESC), 0);

        DELETE f
        FROM dbo.Fact_Invoice AS f
        WHERE f.IsPaid = 0
           OR EXISTS (SELECT 1 FROM Rental.dbo.Invoice AS i
                      WHERE i.InvoiceID = f.InvoiceID AND i.StatusID <> 3)
           OR EXISTS (SELECT 1 FROM Rental.dbo.Payment AS p
                      WHERE p.InvoiceID = f.InvoiceID AND p.PaymentID > @LastPaymentID);

        INSERT INTO dbo.ETL_RowCount (RunID, TableName, RowsInserted, RowsUpdated, RowsError)
        VALUES (@RunID, N'Fact_Invoice (видалено незакриті перед перезавантаженням)', 0, @@ROWCOUNT, 0);
    END;

    TRUNCATE TABLE dbo.Fact_Occupancy;
END;
GO

/* =====================================================================
   3. SCD Type 1 для орендарів: перезапис змінених атрибутів
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_ApplyTenantSCD1
    @RunID INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE d
    SET Name       = s.Name,
        TenantType = s.TenantType,
        TaxCode    = s.TaxCode,
        Phone      = s.Phone,
        Email      = s.Email,
        HasEmail   = s.HasEmail,
        UpdatedAt  = SYSDATETIME()
    FROM dbo.Dim_Tenant AS d
    JOIN dbo.Stage_Tenant AS s ON s.TenantID = d.TenantID;

    INSERT INTO dbo.ETL_RowCount (RunID, TableName, RowsInserted, RowsUpdated, RowsError)
    VALUES (@RunID, N'Dim_Tenant (SCD1 оновлення)', 0, @@ROWCOUNT, 0);
END;
GO

/* =====================================================================
   4. SCD Type 2 для приміщень
      Для кожного зміненого приміщення поточна версія закривається
      (ValidTo = вчора, IsCurrent = 0) і додається нова версія з сьогоднішньої дати.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_ApplyPremisesSCD2
    @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @Changed INT;

    BEGIN TRANSACTION;

        UPDATE d
        SET ValidTo   = DATEADD(DAY, -1, @Today),
            IsCurrent = 0
        FROM dbo.Dim_Premises AS d
        JOIN dbo.Stage_Premises AS s ON s.PremisesID = d.PremisesID
        WHERE d.IsCurrent = 1;

        SET @Changed = @@ROWCOUNT;

        INSERT INTO dbo.Dim_Premises
            (PremisesID, City, Address, Floor, FloorCategory, RoomsCount, Area, AreaCategory,
             PremisesType, TypeGroup, MonthlyPrice, ValidFrom, ValidTo, IsCurrent)
        SELECT
            PremisesID, City, Address, Floor, FloorCategory, RoomsCount, Area, AreaCategory,
            PremisesType, TypeGroup, MonthlyPrice, @Today, '99991231', 1
        FROM dbo.Stage_Premises;

    COMMIT TRANSACTION;

    INSERT INTO dbo.ETL_RowCount (RunID, TableName, RowsInserted, RowsUpdated, RowsError)
    VALUES (@RunID, N'Dim_Premises (SCD2 нові версії)', @Changed, @Changed, 0);
END;
GO

/* =====================================================================
   5. SCD Type 1 для договорів: дострокове розірвання змінює дату закінчення
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_ApplyContractSCD1
    @RunID INT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE d
    SET TerminationDate  = s.TerminationDate,
        EffectiveEndDate = s.EffectiveEndDate,
        DurationMonths   = s.DurationMonths,
        DurationCategory = s.DurationCategory,
        IsTerminated     = s.IsTerminated,
        UpdatedAt        = SYSDATETIME()
    FROM dbo.Dim_Contract AS d
    JOIN dbo.Stage_Contract AS s ON s.ContractID = d.ContractID;

    INSERT INTO dbo.ETL_RowCount (RunID, TableName, RowsInserted, RowsUpdated, RowsError)
    VALUES (@RunID, N'Dim_Contract (SCD1 оновлення)', 0, @@ROWCOUNT, 0);
END;
GO

/* =====================================================================
   6. Корекція ключів приміщень у фактах відповідно до історії SCD2
      ETL підставляє поточну версію приміщення; якщо дата факту належить
      попередній версії, ключ замінюється на ключ тієї версії.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_FixPremisesKeys
    @RunID INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Fixed INT = 0;

    -- Нічого робити, якщо історичних версій немає
    IF NOT EXISTS (SELECT 1 FROM dbo.Dim_Premises WHERE IsCurrent = 0)
        RETURN;

    UPDATE f
    SET PremisesKey = v.PremisesKey
    FROM dbo.Fact_Invoice AS f
    JOIN dbo.Dim_Premises AS cur ON cur.PremisesKey = f.PremisesKey
    JOIN dbo.Dim_Date     AS dd  ON dd.DateKey = f.PeriodDateKey
    JOIN dbo.Dim_Premises AS v   ON v.PremisesID = cur.PremisesID
                                AND dd.FullDate BETWEEN v.ValidFrom AND v.ValidTo
    WHERE v.PremisesKey <> f.PremisesKey;
    SET @Fixed += @@ROWCOUNT;

    UPDATE f
    SET PremisesKey = v.PremisesKey
    FROM dbo.Fact_Payment AS f
    JOIN dbo.Dim_Premises AS cur ON cur.PremisesKey = f.PremisesKey
    JOIN dbo.Dim_Date     AS dd  ON dd.DateKey = f.PaymentDateKey
    JOIN dbo.Dim_Premises AS v   ON v.PremisesID = cur.PremisesID
                                AND dd.FullDate BETWEEN v.ValidFrom AND v.ValidTo
    WHERE v.PremisesKey <> f.PremisesKey;
    SET @Fixed += @@ROWCOUNT;

    INSERT INTO dbo.ETL_RowCount (RunID, TableName, RowsInserted, RowsUpdated, RowsError)
    VALUES (@RunID, N'Факти (ключі історичних версій приміщень)', 0, @Fixed, 0);
END;
GO

/* =====================================================================
   7. Журнал кількості рядків
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_LogRows
    @RunID     INT,
    @TableName NVARCHAR(100),
    @Inserted  INT,
    @Updated   INT,
    @Errors    INT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.ETL_RowCount (RunID, TableName, RowsInserted, RowsUpdated, RowsError)
    VALUES (@RunID, @TableName, ISNULL(@Inserted, 0), ISNULL(@Updated, 0), ISNULL(@Errors, 0));
END;
GO

-- Рахунки завантажуються в циклі по роках — окремий запис на кожен рік
CREATE OR ALTER PROCEDURE dbo.usp_ETL_LogInvoiceYear
    @RunID    INT,
    @Year     INT,
    @Inserted INT,
    @Errors   INT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.ETL_RowCount (RunID, TableName, RowsInserted, RowsUpdated, RowsError)
    VALUES (@RunID, CONCAT(N'Fact_Invoice ', @Year), ISNULL(@Inserted, 0), 0, ISNULL(@Errors, 0));
END;
GO

-- Нові рядки вимірів (оновлення SCD логують процедури SCD)
CREATE OR ALTER PROCEDURE dbo.usp_ETL_LogDimensionRows
    @RunID            INT,
    @DateRows         INT,
    @StatusRows       INT,
    @TenantNew        INT,
    @PremisesNew      INT,
    @ContractNew      INT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.ETL_RowCount (RunID, TableName, RowsInserted, RowsUpdated, RowsError)
    VALUES
        (@RunID, N'Dim_Date',          ISNULL(@DateRows, 0),    0, 0),
        (@RunID, N'Dim_InvoiceStatus', ISNULL(@StatusRows, 0),  0, 0),
        (@RunID, N'Dim_Tenant',        ISNULL(@TenantNew, 0),   0, 0),
        (@RunID, N'Dim_Premises',      ISNULL(@PremisesNew, 0), 0, 0),
        (@RunID, N'Dim_Contract',      ISNULL(@ContractNew, 0), 0, 0);
END;
GO

-- Платежі та завантаженість приміщень
CREATE OR ALTER PROCEDURE dbo.usp_ETL_LogFactRows
    @RunID          INT,
    @PaymentRows    INT,
    @PaymentErrors  INT,
    @OccupancyRows  INT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.ETL_RowCount (RunID, TableName, RowsInserted, RowsUpdated, RowsError)
    VALUES
        (@RunID, N'Fact_Payment',   ISNULL(@PaymentRows, 0),   0, ISNULL(@PaymentErrors, 0)),
        (@RunID, N'Fact_Occupancy', ISNULL(@OccupancyRows, 0), 0, 0);
END;
GO

/* =====================================================================
   8. Звірка джерела і сховища після завантаження
      Повертає розбіжності кількості рядків і кількість відбракованих рядків.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_Reconcile
    @RunID INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        (SELECT COUNT(*) FROM Rental.dbo.Invoice) - (SELECT COUNT(*) FROM dbo.Fact_Invoice) AS DiffInvoices,
        (SELECT COUNT(*) FROM Rental.dbo.Payment) - (SELECT COUNT(*) FROM dbo.Fact_Payment) AS DiffPayments,
        (SELECT COUNT(*) FROM dbo.ETL_ErrorRow WHERE RunID = @RunID)                        AS ErrorRows;
END;
GO

/* =====================================================================
   9. Завершення запуску: статус, час, watermark-и
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_End
    @RunID   INT,
    @Status  NVARCHAR(20),
    @Message NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.ETL_Audit
    SET EndTime       = SYSDATETIME(),
        Status        = CASE WHEN @Status IN (N'Success', N'Warning', N'Failed') THEN @Status ELSE N'Success' END,
        LastInvoiceID = (SELECT ISNULL(MAX(InvoiceID), 0) FROM dbo.Fact_Invoice),
        LastPaymentID = (SELECT ISNULL(MAX(PaymentID), 0) FROM dbo.Fact_Payment),
        Message       = CONCAT(Message, CASE WHEN Message IS NOT NULL AND @Message IS NOT NULL THEN N' ' END, @Message)
    WHERE RunID = @RunID;
END;
GO

/* =====================================================================
   10. Помилка виконання (викликається з Event Handler OnError)
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_LogError
    @RunID            INT,
    @SourceName       NVARCHAR(200),
    @ErrorCode        INT,
    @ErrorDescription NVARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.ETL_ErrorLog (RunID, SourceName, ErrorCode, ErrorDescription)
    VALUES (NULLIF(@RunID, 0), ISNULL(@SourceName, N''), ISNULL(@ErrorCode, 0), ISNULL(@ErrorDescription, N''));

    UPDATE dbo.ETL_Audit
    SET Status = N'Failed', EndTime = SYSDATETIME()
    WHERE RunID = @RunID;
END;
GO

/* =====================================================================
   11. Звіт про запуски ETL
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_ETL_RunSummary
AS
SELECT
    a.RunID,
    a.RequestedMode,
    a.LoadMode,
    a.Status,
    a.StartTime,
    a.EndTime,
    DATEDIFF(SECOND, a.StartTime, a.EndTime)                       AS DurationSec,
    ISNULL(rc.RowsInserted, 0)                                     AS RowsInserted,
    ISNULL(rc.RowsUpdated, 0)                                      AS RowsUpdated,
    ISNULL(rc.RowsError, 0)                                        AS RowsError,
    (SELECT COUNT(*) FROM dbo.ETL_ErrorLog AS e WHERE e.RunID = a.RunID) AS PackageErrors,
    a.LastInvoiceID,
    a.LastPaymentID,
    a.Message
FROM dbo.ETL_Audit AS a
OUTER APPLY (SELECT SUM(RowsInserted) AS RowsInserted,
                    SUM(RowsUpdated)  AS RowsUpdated,
                    SUM(RowsError)    AS RowsError
             FROM dbo.ETL_RowCount AS r
             WHERE r.RunID = a.RunID) AS rc;
GO

PRINT N'Процедури ETL створено.';
GO
