USE [Rental];
GO

/* --------------------------------------------------------------------------
   Допоміжна функція: обчислення статусу рахунку
     1 = Не оплачено, 2 = Частково оплачено, 3 = Оплачено, 4 = Прострочено
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_CalcInvoiceStatus
(
    @TotalAmount  DECIMAL(14,2),
    @PaidAmount   DECIMAL(14,2),
    @DueDate      DATE,
    @AsOfDate     DATE
)
RETURNS INT
AS
BEGIN
    RETURN CASE
        WHEN @PaidAmount >= @TotalAmount THEN 3   -- Оплачено
        WHEN @DueDate < @AsOfDate        THEN 4   -- Прострочено (термін минув, оплачено не повністю)
        WHEN @PaidAmount > 0             THEN 2   -- Частково оплачено
        ELSE 1                                    -- Не оплачено
    END;
END;
GO

/* --------------------------------------------------------------------------
   Тригер 1. Договір: немає перетину періодів оренди одного приміщення;
   рахунки договору лишаються в межах його періоду.
   -------------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.TR_Contract_Validate
ON dbo.Contract
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;

    -- Перевіряємо лише якщо змінилось приміщення або дати
    IF NOT (UPDATE(PremisesID) OR UPDATE(StartDate) OR UPDATE(EndDate) OR UPDATE(TerminationDate))
        RETURN;

    -- Перетин періодів: [S1; E1] і [S2; E2] перетинаються, якщо S1 <= E2 і S2 <= E1
    IF EXISTS (
        SELECT 1
        FROM inserted AS i
        JOIN dbo.Contract AS c
          ON  c.PremisesID = i.PremisesID
          AND c.ContractID <> i.ContractID
          AND c.StartDate <= COALESCE(i.TerminationDate, i.EndDate)
          AND i.StartDate <= COALESCE(c.TerminationDate, c.EndDate)
    )
    BEGIN
        ;THROW 50001, N'Приміщення вже орендоване в цей період за іншим договором.', 1;
    END;

    -- Після зміни дат усі рахунки договору мають лишатися в межах періоду оренди
    IF EXISTS (
        SELECT 1
        FROM inserted AS i
        JOIN dbo.Invoice AS inv ON inv.ContractID = i.ContractID
        WHERE inv.PeriodMonth > COALESCE(i.TerminationDate, i.EndDate)
           OR EOMONTH(inv.PeriodMonth) < i.StartDate
    )
    BEGIN
        ;THROW 50002, N'Нові дати договору залишають виставлені рахунки поза періодом оренди.', 1;
    END;
END;
GO

/* --------------------------------------------------------------------------
   Тригер 2. Рахунок: період у межах дії договору, сума не менша за вже
   сплачене; після вставки/зміни сум — перерахунок статусу.
   -------------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.TR_Invoice_Validate
ON dbo.Invoice
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;

    -- Якщо змінено лише StatusID (це робить TR_Payment_RecalcInvoice
    -- або sp_RefreshInvoiceStatuses) — перевіряти нічого
    IF NOT (UPDATE(ContractID) OR UPDATE(PeriodMonth) OR UPDATE(DueDate)
            OR UPDATE(RentAmount) OR UPDATE(UtilitiesAmount) OR UPDATE(PenaltyAmount))
        RETURN;

    -- Рахунок лише за місяць, у якому договір діяв хоча б один день
    IF EXISTS (
        SELECT 1
        FROM inserted AS i
        JOIN dbo.Contract AS c ON c.ContractID = i.ContractID
        WHERE i.PeriodMonth > COALESCE(c.TerminationDate, c.EndDate)
           OR EOMONTH(i.PeriodMonth) < c.StartDate
    )
    BEGIN
        ;THROW 50010, N'Рахунок виставлено за місяць, у якому договір не діяв.', 1;
    END;

    -- Сума рахунку не може стати меншою за вже сплачену суму
    IF EXISTS (
        SELECT 1
        FROM inserted AS i
        CROSS APPLY (SELECT SUM(p.Amount) AS Paid
                     FROM dbo.Payment AS p
                     WHERE p.InvoiceID = i.InvoiceID) AS s
        WHERE s.Paid > i.TotalAmount
    )
    BEGIN
        ;THROW 50011, N'Сума рахунку менша за суму вже зареєстрованих платежів.', 1;
    END;

    -- Перерахунок статусу
    UPDATE inv
    SET StatusID = dbo.fn_CalcInvoiceStatus(inv.TotalAmount, ISNULL(s.Paid, 0),
                                            inv.DueDate, CAST(GETDATE() AS DATE))
    FROM dbo.Invoice AS inv
    JOIN inserted AS i ON i.InvoiceID = inv.InvoiceID
    OUTER APPLY (SELECT SUM(p.Amount) AS Paid
                 FROM dbo.Payment AS p
                 WHERE p.InvoiceID = inv.InvoiceID) AS s;
END;
GO

/* --------------------------------------------------------------------------
   Тригер 3. Платіж: без переплати, не раніше дати рахунку;
   після будь-якої зміни платежів — перерахунок статусу рахунку.
   -------------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.TR_Payment_RecalcInvoice
ON dbo.Payment
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- Рахунки, яких стосується операція (і нові, і старі значення InvoiceID)
    CREATE TABLE #Affected (InvoiceID INT PRIMARY KEY);

    INSERT INTO #Affected (InvoiceID)
    SELECT InvoiceID FROM inserted
    UNION
    SELECT InvoiceID FROM deleted;

    IF NOT EXISTS (SELECT 1 FROM #Affected)
        RETURN;

    -- Платіж не може бути раніше дати виставлення рахунку
    IF EXISTS (
        SELECT 1
        FROM inserted AS p
        JOIN dbo.Invoice AS inv ON inv.InvoiceID = p.InvoiceID
        WHERE p.PaymentDate < inv.IssueDate
    )
    BEGIN
        ;THROW 50020, N'Дата платежу раніша за дату виставлення рахунку.', 1;
    END;

    -- Сума платежів не може перевищувати суму рахунку
    IF EXISTS (
        SELECT 1
        FROM #Affected AS a
        JOIN dbo.Invoice AS inv ON inv.InvoiceID = a.InvoiceID
        CROSS APPLY (SELECT SUM(p.Amount) AS Paid
                     FROM dbo.Payment AS p
                     WHERE p.InvoiceID = a.InvoiceID) AS s
        WHERE s.Paid > inv.TotalAmount
    )
    BEGIN
        ;THROW 50021, N'Сума платежів перевищує суму рахунку.', 1;
    END;

    -- Перерахунок статусу рахунків
    UPDATE inv
    SET StatusID = dbo.fn_CalcInvoiceStatus(inv.TotalAmount, ISNULL(s.Paid, 0),
                                            inv.DueDate, CAST(GETDATE() AS DATE))
    FROM dbo.Invoice AS inv
    JOIN #Affected AS a ON a.InvoiceID = inv.InvoiceID
    OUTER APPLY (SELECT SUM(p.Amount) AS Paid
                 FROM dbo.Payment AS p
                 WHERE p.InvoiceID = inv.InvoiceID) AS s;
END;
GO

PRINT N'Функцію статусу та тригери створено.';
GO
