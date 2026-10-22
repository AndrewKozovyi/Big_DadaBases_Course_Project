USE [Rental];
GO

-- Видалення у зворотному порядку залежностей (для повторного запуску)
DROP TABLE IF EXISTS dbo.Payment;
DROP TABLE IF EXISTS dbo.Invoice;
DROP TABLE IF EXISTS dbo.InvoiceStatus;
DROP TABLE IF EXISTS dbo.Contract;
DROP TABLE IF EXISTS dbo.Tenant;
DROP TABLE IF EXISTS dbo.TenantType;
DROP TABLE IF EXISTS dbo.Premises;
DROP TABLE IF EXISTS dbo.PremisesType;
GO

/* ---------- Довідник: типи приміщень (18 записів) ---------- */
CREATE TABLE dbo.PremisesType
(
    TypeID  INT IDENTITY(1,1) NOT NULL,
    Name    NVARCHAR(100)     NOT NULL,
    CONSTRAINT PK_PremisesType PRIMARY KEY CLUSTERED (TypeID)
);
GO

/* ---------- Приміщення (5 000 записів) ---------- */
CREATE TABLE dbo.Premises
(
    PremisesID    INT IDENTITY(1,1) NOT NULL,
    TypeID        INT               NOT NULL,
    City          NVARCHAR(50)      NOT NULL,
    Address       NVARCHAR(200)     NOT NULL,   -- вулиця, будинок, квартира/офіс/приміщення
    Floor         SMALLINT          NULL,       -- поверх: від'ємний — підземний, 0 — цокольний, NULL — окремий будинок
    RoomsCount    SMALLINT          NOT NULL,
    Area          DECIMAL(9,2)      NOT NULL,   -- площа, м²
    MonthlyPrice  DECIMAL(12,2)     NOT NULL,   -- поточна ціна оренди за місяць, грн
    CONSTRAINT PK_Premises PRIMARY KEY CLUSTERED (PremisesID)
);
GO

/* ---------- Довідник: типи орендарів (3 записи, фіксовані ID) ---------- */
CREATE TABLE dbo.TenantType
(
    TenantTypeID  INT           NOT NULL,
    Name          NVARCHAR(50)  NOT NULL,
    CONSTRAINT PK_TenantType PRIMARY KEY CLUSTERED (TenantTypeID)
);
GO

/* ---------- Орендарі (50 000 записів) ---------- */
CREATE TABLE dbo.Tenant
(
    TenantID      INT IDENTITY(1,1) NOT NULL,
    TenantTypeID  INT               NOT NULL,
    Name          NVARCHAR(150)     NOT NULL,   -- ПІБ або назва компанії
    TaxCode       VARCHAR(10)       NOT NULL,   -- ЄДРПОУ (8 цифр) або РНОКПП (10 цифр)
    Phone         VARCHAR(13)       NOT NULL,   -- формат +380XXXXXXXXX
    Email         NVARCHAR(100)     NULL,
    CONSTRAINT PK_Tenant PRIMARY KEY CLUSTERED (TenantID)
);
GO

/* ---------- Договори оренди (100 000 записів) ---------- */
CREATE TABLE dbo.Contract
(
    ContractID       INT IDENTITY(1,1) NOT NULL,
    ContractNumber   VARCHAR(20)       NOT NULL,
    TenantID         INT               NOT NULL,
    PremisesID       INT               NOT NULL,
    SignDate         DATE              NOT NULL,
    StartDate        DATE              NOT NULL,   -- перший день оренди
    EndDate          DATE              NOT NULL,   -- останній день оренди за договором (включно)
    TerminationDate  DATE              NULL,       -- останній день оренди при достроковому розірванні
    MonthlyRent      DECIMAL(12,2)     NOT NULL,   -- ціна, зафіксована в договорі
    Deposit          DECIMAL(12,2)     NOT NULL,
    PaymentDay       TINYINT           NOT NULL,   -- число місяця, до якого треба оплатити рахунок
    CONSTRAINT PK_Contract PRIMARY KEY CLUSTERED (ContractID)
);
GO

/* ---------- Довідник: статуси рахунків (4 записи, фіксовані ID) ---------- */
CREATE TABLE dbo.InvoiceStatus
(
    StatusID  INT           NOT NULL,
    Name      NVARCHAR(30)  NOT NULL,
    CONSTRAINT PK_InvoiceStatus PRIMARY KEY CLUSTERED (StatusID)
);
GO

/* ---------- Рахунки (210 000 записів) ---------- */
CREATE TABLE dbo.Invoice
(
    InvoiceID        INT IDENTITY(1,1) NOT NULL,
    InvoiceNumber    VARCHAR(20)       NOT NULL,
    ContractID       INT               NOT NULL,
    StatusID         INT               NOT NULL,
    PeriodMonth      DATE              NOT NULL,   -- перше число місяця, за який виставлено рахунок
    IssueDate        DATE              NOT NULL,
    DueDate          DATE              NOT NULL,
    RentAmount       DECIMAL(12,2)     NOT NULL,
    UtilitiesAmount  DECIMAL(12,2)     NOT NULL,
    PenaltyAmount    DECIMAL(12,2)     NOT NULL,
    TotalAmount      AS (RentAmount + UtilitiesAmount + PenaltyAmount) PERSISTED,
    CONSTRAINT PK_Invoice PRIMARY KEY CLUSTERED (InvoiceID)
);
GO

/* ---------- Платежі (~195 000 записів) ---------- */
CREATE TABLE dbo.Payment
(
    PaymentID       INT IDENTITY(1,1) NOT NULL,
    InvoiceID       INT               NOT NULL,
    PaymentDate     DATE              NOT NULL,
    Amount          DECIMAL(12,2)     NOT NULL,
    DocumentNumber  VARCHAR(30)       NULL,      -- номер платіжного документа
    CONSTRAINT PK_Payment PRIMARY KEY CLUSTERED (PaymentID)
);
GO

PRINT N'Таблиці створено.';
GO
