USE [Rental];
GO

/* ======================= FOREIGN KEY ======================= */
-- ON DELETE / ON UPDATE NO ACTION: не можна видалити тип, приміщення, орендаря,
-- договір чи рахунок, на які посилаються інші записи (історія оренди зберігається).

ALTER TABLE dbo.Premises
    ADD CONSTRAINT FK_Premises_PremisesType
        FOREIGN KEY (TypeID) REFERENCES dbo.PremisesType (TypeID);

ALTER TABLE dbo.Tenant
    ADD CONSTRAINT FK_Tenant_TenantType
        FOREIGN KEY (TenantTypeID) REFERENCES dbo.TenantType (TenantTypeID);

ALTER TABLE dbo.Contract
    ADD CONSTRAINT FK_Contract_Tenant
        FOREIGN KEY (TenantID) REFERENCES dbo.Tenant (TenantID);

ALTER TABLE dbo.Contract
    ADD CONSTRAINT FK_Contract_Premises
        FOREIGN KEY (PremisesID) REFERENCES dbo.Premises (PremisesID);

ALTER TABLE dbo.Invoice
    ADD CONSTRAINT FK_Invoice_Contract
        FOREIGN KEY (ContractID) REFERENCES dbo.Contract (ContractID);

ALTER TABLE dbo.Invoice
    ADD CONSTRAINT FK_Invoice_InvoiceStatus
        FOREIGN KEY (StatusID) REFERENCES dbo.InvoiceStatus (StatusID);

ALTER TABLE dbo.Payment
    ADD CONSTRAINT FK_Payment_Invoice
        FOREIGN KEY (InvoiceID) REFERENCES dbo.Invoice (InvoiceID);
GO

/* ======================= UNIQUE ======================= */

ALTER TABLE dbo.PremisesType
    ADD CONSTRAINT UQ_PremisesType_Name UNIQUE (Name);

-- Однакова адреса може існувати в різних містах, тому унікальна саме пара
ALTER TABLE dbo.Premises
    ADD CONSTRAINT UQ_Premises_City_Address UNIQUE (City, Address);

ALTER TABLE dbo.TenantType
    ADD CONSTRAINT UQ_TenantType_Name UNIQUE (Name);

ALTER TABLE dbo.Tenant
    ADD CONSTRAINT UQ_Tenant_TaxCode UNIQUE (TaxCode);

ALTER TABLE dbo.Contract
    ADD CONSTRAINT UQ_Contract_ContractNumber UNIQUE (ContractNumber);

ALTER TABLE dbo.InvoiceStatus
    ADD CONSTRAINT UQ_InvoiceStatus_Name UNIQUE (Name);

ALTER TABLE dbo.Invoice
    ADD CONSTRAINT UQ_Invoice_InvoiceNumber UNIQUE (InvoiceNumber);

-- Один рахунок на договір за кожен місяць
ALTER TABLE dbo.Invoice
    ADD CONSTRAINT UQ_Invoice_Contract_Period UNIQUE (ContractID, PeriodMonth);
GO

/* ======================= CHECK ======================= */

-- Приміщення
ALTER TABLE dbo.Premises
    ADD CONSTRAINT CK_Premises_Floor        CHECK (Floor IS NULL OR Floor BETWEEN -5 AND 100),
        CONSTRAINT CK_Premises_RoomsCount   CHECK (RoomsCount > 0),
        CONSTRAINT CK_Premises_Area         CHECK (Area > 0),
        CONSTRAINT CK_Premises_MonthlyPrice CHECK (MonthlyPrice > 0);

-- Орендар: податковий код лише з цифр; довжина залежить від типу орендаря
--   TenantTypeID 1 = Фізична особа, 2 = ФОП  -> РНОКПП, 10 цифр
--   TenantTypeID 3 = Юридична особа         -> ЄДРПОУ, 8 цифр
ALTER TABLE dbo.Tenant
    ADD CONSTRAINT CK_Tenant_TaxCode CHECK (
            TaxCode NOT LIKE '%[^0-9]%'
        AND (   (TenantTypeID IN (1, 2) AND LEN(TaxCode) = 10)
             OR (TenantTypeID = 3       AND LEN(TaxCode) = 8))
        ),
        CONSTRAINT CK_Tenant_Phone CHECK (
            Phone LIKE '+380[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        ),
        CONSTRAINT CK_Tenant_Email CHECK (
            Email IS NULL OR Email LIKE '%_@_%._%'
        );

-- Договір
ALTER TABLE dbo.Contract
    ADD CONSTRAINT CK_Contract_Dates CHECK (
            StartDate >= SignDate
        AND EndDate   >  StartDate
        ),
        CONSTRAINT CK_Contract_TerminationDate CHECK (
            TerminationDate IS NULL
         OR (TerminationDate >= StartDate AND TerminationDate < EndDate)
        ),
        CONSTRAINT CK_Contract_MonthlyRent CHECK (MonthlyRent > 0),
        CONSTRAINT CK_Contract_Deposit     CHECK (Deposit >= 0),
        CONSTRAINT CK_Contract_PaymentDay  CHECK (PaymentDay BETWEEN 1 AND 28);

-- Рахунок
ALTER TABLE dbo.Invoice
    ADD CONSTRAINT CK_Invoice_PeriodMonth     CHECK (DAY(PeriodMonth) = 1),
        CONSTRAINT CK_Invoice_Dates           CHECK (DueDate >= IssueDate),
        CONSTRAINT CK_Invoice_RentAmount      CHECK (RentAmount > 0),
        CONSTRAINT CK_Invoice_UtilitiesAmount CHECK (UtilitiesAmount >= 0),
        CONSTRAINT CK_Invoice_PenaltyAmount   CHECK (PenaltyAmount >= 0);

-- Платіж
ALTER TABLE dbo.Payment
    ADD CONSTRAINT CK_Payment_Amount CHECK (Amount > 0);
GO

/* ======================= DEFAULT ======================= */

ALTER TABLE dbo.Contract
    ADD CONSTRAINT DF_Contract_Deposit    DEFAULT (0)  FOR Deposit,
        CONSTRAINT DF_Contract_PaymentDay DEFAULT (10) FOR PaymentDay;

ALTER TABLE dbo.Invoice
    ADD CONSTRAINT DF_Invoice_StatusID        DEFAULT (1) FOR StatusID,   -- «Не оплачено»
        CONSTRAINT DF_Invoice_UtilitiesAmount DEFAULT (0) FOR UtilitiesAmount,
        CONSTRAINT DF_Invoice_PenaltyAmount   DEFAULT (0) FOR PenaltyAmount;

ALTER TABLE dbo.Payment
    ADD CONSTRAINT DF_Payment_PaymentDate DEFAULT (CAST(GETDATE() AS DATE)) FOR PaymentDate;
GO

PRINT N'Обмеження цілісності створено.';
GO
