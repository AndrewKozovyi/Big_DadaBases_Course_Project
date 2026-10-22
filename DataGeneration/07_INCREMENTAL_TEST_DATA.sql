USE [Rental];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Нові та змінені дані для перевірки інкрементального завантаження (LoadMode = INCREMENTAL).
-- Кожен блок імітує реальну операцію і перевіряє окремий механізм ETL:
--   1) зміна телефонів орендарів          -> SCD1 у Dim_Tenant (перезапис);
--   2) підвищення ціни приміщень          -> SCD2 у Dim_Premises (нова версія рядка);
--   3) дострокове розірвання договорів    -> SCD1 у Dim_Contract;
--   4) новий орендар і новий договір      -> нові рядки вимірів;
--   5) оплата старих боргів               -> нові рядки Fact_Payment і перезавантаження рахунків;
--   6) рахунки за наступний місяць        -> нові рядки Fact_Invoice.
-- Операції йдуть через процедури та тригери бази, тому всі бізнес-правила перевіряються.

DECLARE @Today     DATE = CAST(GETDATE() AS DATE);
DECLARE @NextMonth DATE = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1));

DECLARE @Result TABLE (Step NVARCHAR(100), Rows INT);

/* 1. SCD1: нові номери телефонів у 10 орендарів */
UPDATE dbo.Tenant
SET Phone = '+38050' + RIGHT('0000000' + CAST(TenantID * 7919 AS VARCHAR(10)), 7)
WHERE TenantID BETWEEN 1 AND 10;
INSERT INTO @Result VALUES (N'1. Змінено телефонів орендарів', @@ROWCOUNT);

/* 2. SCD2: ціна оренди 20 приміщень зросла на 10 % */
UPDATE dbo.Premises
SET MonthlyPrice = ROUND(MonthlyPrice * 1.10, 2)
WHERE PremisesID BETWEEN 1 AND 20;
INSERT INTO @Result VALUES (N'2. Підвищено ціну приміщень', @@ROWCOUNT);

/* 3. SCD1: дострокове розірвання 5 чинних договорів з кінця поточного місяця.
      Беремо договори, що тривають після наступного місяця й не мають рахунків пізніше поточного. */
DECLARE @Terminated INT = 0, @ContractID INT, @EndOfMonth DATE = EOMONTH(@Today);

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT TOP (5) ct.ContractID
    FROM dbo.Contract AS ct
    WHERE ct.TerminationDate IS NULL
      AND ct.StartDate <= @Today
      AND ct.EndDate   >  EOMONTH(@NextMonth)
      AND NOT EXISTS (SELECT 1 FROM dbo.Invoice AS i
                      WHERE i.ContractID = ct.ContractID AND i.PeriodMonth > @EndOfMonth)
    ORDER BY ct.ContractID;
OPEN c;
FETCH NEXT FROM c INTO @ContractID;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.sp_TerminateContract @ContractID = @ContractID, @TerminationDate = @EndOfMonth;
    SET @Terminated += 1;
    FETCH NEXT FROM c INTO @ContractID;
END;
CLOSE c;
DEALLOCATE c;
INSERT INTO @Result VALUES (N'3. Розірвано договорів', @Terminated);

/* 4. Новий орендар (юридична особа) і договір на 6 місяців з наступного місяця
      на вільне нежитлове приміщення */
DECLARE @TaxCode VARCHAR(10) = (SELECT CAST(MIN(n) AS VARCHAR(10))
                                FROM (VALUES (99000001), (99000002), (99000003), (99000004), (99000005)) AS v(n)
                                WHERE NOT EXISTS (SELECT 1 FROM dbo.Tenant WHERE TaxCode = CAST(v.n AS VARCHAR(10))));
DECLARE @TenantID INT, @PremisesID INT, @NewContractID INT;
DECLARE @NewEnd DATE = DATEADD(DAY, -1, DATEADD(MONTH, 6, @NextMonth));

IF @TaxCode IS NOT NULL
BEGIN
    INSERT INTO dbo.Tenant (TenantTypeID, Name, TaxCode, Phone, Email)
    VALUES (3, N'ТОВ «Нова Оренда ' + RIGHT(@TaxCode, 1) + N'»', @TaxCode, '+380441234567', N'office@nova-orenda.ua');
    SET @TenantID = SCOPE_IDENTITY();

    SELECT TOP (1) @PremisesID = p.PremisesID
    FROM dbo.Premises AS p
    JOIN dbo.PremisesType AS pt ON pt.TypeID = p.TypeID
    WHERE pt.Name NOT IN (N'Квартира', N'Будинок', N'Кімната')
      AND NOT EXISTS (SELECT 1 FROM dbo.Contract AS ct
                      WHERE ct.PremisesID = p.PremisesID
                        AND ct.StartDate <= @NewEnd
                        AND COALESCE(ct.TerminationDate, ct.EndDate) >= @NextMonth)
    ORDER BY p.PremisesID;

    EXEC dbo.sp_CreateContract
        @TenantID   = @TenantID,
        @PremisesID = @PremisesID,
        @StartDate  = @NextMonth,
        @EndDate    = @NewEnd,
        @SignDate   = @Today,
        @ContractID = @NewContractID OUTPUT;
END;
INSERT INTO @Result VALUES (N'4. Новий орендар + договір (ContractID)', @NewContractID);

/* 5. Повна оплата 300 найстаріших неоплачених рахунків сьогоднішньою датою.
      Тригер TR_Payment_RecalcInvoice перерахує їхні статуси на «Оплачено». */
INSERT INTO dbo.Payment (InvoiceID, PaymentDate, Amount, DocumentNumber)
SELECT TOP (300)
    i.InvoiceID,
    @Today,
    i.TotalAmount - ISNULL(s.Paid, 0),
    CONCAT('PP-INC-', i.InvoiceID)
FROM dbo.Invoice AS i
OUTER APPLY (SELECT SUM(p.Amount) AS Paid FROM dbo.Payment AS p WHERE p.InvoiceID = i.InvoiceID) AS s
WHERE i.StatusID <> 3
  AND i.IssueDate <= @Today
  AND i.TotalAmount - ISNULL(s.Paid, 0) > 0
ORDER BY i.DueDate, i.InvoiceID;
INSERT INTO @Result VALUES (N'5. Нових платежів (погашення боргів)', @@ROWCOUNT);

/* 6. Рахунки за наступний місяць усім договорам, що в ньому діють
      (процедура повертає кількість створених рахунків) */
DECLARE @Inv TABLE (InvoicesCreated INT);
INSERT INTO @Inv EXEC dbo.sp_GenerateMonthlyInvoices @PeriodMonth = @NextMonth;
INSERT INTO @Result SELECT N'6. Нових рахунків за ' + FORMAT(@NextMonth, 'MM.yyyy'), InvoicesCreated FROM @Inv;

SELECT Step AS [Крок], Rows AS [Рядків] FROM @Result;
GO
