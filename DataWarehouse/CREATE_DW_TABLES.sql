USE [RentalDW];
GO

-- Дати зберігаються як DATETIME: SSIS-підключення використовують провайдер SQLOLEDB (як у Lab1),
-- який не підтримує тип DATE і передає його як текст.

-- Видалення у зворотному порядку залежностей (для повторного запуску).
-- УВАГА: усі дані сховища зникнуть; після цього потрібен повний ETL (LoadMode = FULL).
DROP VIEW  IF EXISTS dbo.vw_ETL_RunSummary;
DROP TABLE IF EXISTS dbo.Fact_Occupancy;
DROP TABLE IF EXISTS dbo.Fact_Payment;
DROP TABLE IF EXISTS dbo.Fact_Invoice;
DROP TABLE IF EXISTS dbo.Dim_Contract;
DROP TABLE IF EXISTS dbo.Dim_Premises;
DROP TABLE IF EXISTS dbo.Dim_Tenant;
DROP TABLE IF EXISTS dbo.Dim_InvoiceStatus;
DROP TABLE IF EXISTS dbo.Dim_Date;
DROP TABLE IF EXISTS dbo.Ref_Holiday;
DROP TABLE IF EXISTS dbo.Stage_Tenant;
DROP TABLE IF EXISTS dbo.Stage_Premises;
DROP TABLE IF EXISTS dbo.Stage_Contract;
DROP TABLE IF EXISTS dbo.ETL_RowCount;
DROP TABLE IF EXISTS dbo.ETL_ErrorRow;
DROP TABLE IF EXISTS dbo.ETL_ErrorLog;
DROP TABLE IF EXISTS dbo.ETL_Audit;
GO

/* =====================================================================
   ДОВІДКОВА ТАБЛИЦЯ: державні свята України (для атрибута IsHoliday у Dim_Date)
   ===================================================================== */
CREATE TABLE dbo.Ref_Holiday
(
    HolidayDate  DATE           NOT NULL,
    HolidayName  NVARCHAR(100)  NOT NULL,
    CONSTRAINT PK_Ref_Holiday PRIMARY KEY CLUSTERED (HolidayDate)
);
GO

/* =====================================================================
   ВИМІРИ
   ===================================================================== */

-- Календар: ключ yyyymmdd, ієрархія Рік → Квартал → Місяць → День
CREATE TABLE dbo.Dim_Date
(
    DateKey        INT            NOT NULL,   -- yyyymmdd
    FullDate       DATETIME       NOT NULL,
    [Year]         SMALLINT       NOT NULL,
    [Quarter]      TINYINT        NOT NULL,
    QuarterName    NVARCHAR(10)   NOT NULL,   -- «1 квартал»
    [Month]        TINYINT        NOT NULL,
    MonthName      NVARCHAR(20)   NOT NULL,   -- «Січень»
    YearMonth      INT            NOT NULL,   -- yyyymm
    [Day]          TINYINT        NOT NULL,
    DayOfWeek      TINYINT        NOT NULL,   -- 1 = понеділок … 7 = неділя
    DayName        NVARCHAR(15)   NOT NULL,
    WeekOfYear     TINYINT        NOT NULL,
    IsWeekend      BIT            NOT NULL,
    IsHoliday      BIT            NOT NULL,
    HolidayName    NVARCHAR(100)  NULL,
    IsWorkingDay   BIT            NOT NULL,
    CONSTRAINT PK_Dim_Date PRIMARY KEY CLUSTERED (DateKey),
    CONSTRAINT UQ_Dim_Date_FullDate UNIQUE (FullDate)
);
GO

-- Статуси рахунків (SCD Type 0 — не змінюються)
CREATE TABLE dbo.Dim_InvoiceStatus
(
    StatusKey   INT IDENTITY(1,1) NOT NULL,
    StatusID    INT               NOT NULL,   -- бізнес-ключ з OLTP
    StatusName  NVARCHAR(30)      NOT NULL,
    CONSTRAINT PK_Dim_InvoiceStatus PRIMARY KEY CLUSTERED (StatusKey),
    CONSTRAINT UQ_Dim_InvoiceStatus_StatusID UNIQUE (StatusID)
);
GO

-- Орендарі (SCD Type 1 — зміни перезаписуються)
CREATE TABLE dbo.Dim_Tenant
(
    TenantKey   INT IDENTITY(1,1) NOT NULL,
    TenantID    INT               NOT NULL,   -- бізнес-ключ з OLTP
    Name        NVARCHAR(150)     NOT NULL,
    TenantType  NVARCHAR(50)      NOT NULL,
    TaxCode     NVARCHAR(10)      NOT NULL,
    Phone       NVARCHAR(13)      NOT NULL,
    Email       NVARCHAR(100)     NOT NULL,   -- «не вказано», якщо в OLTP NULL
    HasEmail    BIT               NOT NULL,
    UpdatedAt   DATETIME          NULL,       -- коли рядок востаннє оновлено (SCD1)
    CONSTRAINT PK_Dim_Tenant PRIMARY KEY CLUSTERED (TenantKey),
    CONSTRAINT UQ_Dim_Tenant_TenantID UNIQUE (TenantID)
);
GO

-- Приміщення (SCD Type 2 — зміна ціни / типу / площі / кімнат створює нову версію)
CREATE TABLE dbo.Dim_Premises
(
    PremisesKey    INT IDENTITY(1,1) NOT NULL,
    PremisesID     INT               NOT NULL,   -- бізнес-ключ з OLTP
    City           NVARCHAR(50)      NOT NULL,
    Address        NVARCHAR(200)     NOT NULL,
    Floor          SMALLINT          NULL,
    FloorCategory  NVARCHAR(30)      NOT NULL,
    RoomsCount     SMALLINT          NOT NULL,
    Area           DECIMAL(9,2)      NOT NULL,
    AreaCategory   NVARCHAR(30)      NOT NULL,
    PremisesType   NVARCHAR(100)     NOT NULL,
    TypeGroup      NVARCHAR(50)      NOT NULL,
    MonthlyPrice   DECIMAL(12,2)     NOT NULL,
    ValidFrom      DATETIME          NOT NULL CONSTRAINT DF_Dim_Premises_ValidFrom DEFAULT ('19000101'),
    ValidTo        DATETIME          NOT NULL CONSTRAINT DF_Dim_Premises_ValidTo   DEFAULT ('99991231'),
    IsCurrent      BIT               NOT NULL CONSTRAINT DF_Dim_Premises_IsCurrent DEFAULT (1),
    CONSTRAINT PK_Dim_Premises PRIMARY KEY CLUSTERED (PremisesKey)
);
GO

-- Лише одна поточна версія кожного приміщення
CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_Premises_Current
    ON dbo.Dim_Premises (PremisesID) WHERE IsCurrent = 1;
CREATE NONCLUSTERED INDEX IX_Dim_Premises_History
    ON dbo.Dim_Premises (PremisesID, ValidFrom, ValidTo) INCLUDE (PremisesKey);
GO

-- Договори (SCD Type 1)
CREATE TABLE dbo.Dim_Contract
(
    ContractKey       INT IDENTITY(1,1) NOT NULL,
    ContractID        INT               NOT NULL,   -- бізнес-ключ з OLTP
    ContractNumber    NVARCHAR(20)      NOT NULL,
    SignDate          DATETIME          NOT NULL,
    StartDate         DATETIME          NOT NULL,
    EndDate           DATETIME          NOT NULL,
    TerminationDate   DATETIME          NULL,
    EffectiveEndDate  DATETIME          NOT NULL,   -- дата розірвання або закінчення
    DurationMonths    INT               NOT NULL,
    DurationCategory  NVARCHAR(30)      NOT NULL,
    IsTerminated      BIT               NOT NULL,
    MonthlyRent       DECIMAL(12,2)     NOT NULL,
    Deposit           DECIMAL(12,2)     NOT NULL,
    PaymentDay        TINYINT           NOT NULL,
    UpdatedAt         DATETIME          NULL,
    CONSTRAINT PK_Dim_Contract PRIMARY KEY CLUSTERED (ContractKey),
    CONSTRAINT UQ_Dim_Contract_ContractID UNIQUE (ContractID)
);
GO

/* =====================================================================
   ФАКТИ
   ===================================================================== */

-- Рахунки: один рядок = один рахунок; сплачена сума агрегується з платежів
CREATE TABLE dbo.Fact_Invoice
(
    InvoiceID           INT            NOT NULL,   -- вироджений вимір (номер рахунку з OLTP)
    InvoiceNumber       NVARCHAR(20)   NOT NULL,
    PeriodDateKey       INT            NOT NULL,
    IssueDateKey        INT            NOT NULL,
    DueDateKey          INT            NOT NULL,
    LastPaymentDateKey  INT            NULL,
    ContractKey         INT            NOT NULL,
    TenantKey           INT            NOT NULL,
    PremisesKey         INT            NOT NULL,
    StatusKey           INT            NOT NULL,
    RentAmount          DECIMAL(12,2)  NOT NULL,
    UtilitiesAmount     DECIMAL(12,2)  NOT NULL,
    PenaltyAmount       DECIMAL(12,2)  NOT NULL,
    TotalAmount         DECIMAL(14,2)  NOT NULL,
    PaidAmount          DECIMAL(14,2)  NOT NULL,
    DebtAmount          DECIMAL(14,2)  NOT NULL,
    DaysOverdue         INT            NOT NULL,
    IsPaid              BIT            NOT NULL,
    RunID               INT            NOT NULL,   -- запуск ETL, що завантажив рядок
    CONSTRAINT PK_Fact_Invoice PRIMARY KEY CLUSTERED (InvoiceID),
    CONSTRAINT FK_Fact_Invoice_PeriodDate  FOREIGN KEY (PeriodDateKey)      REFERENCES dbo.Dim_Date (DateKey),
    CONSTRAINT FK_Fact_Invoice_IssueDate   FOREIGN KEY (IssueDateKey)       REFERENCES dbo.Dim_Date (DateKey),
    CONSTRAINT FK_Fact_Invoice_DueDate     FOREIGN KEY (DueDateKey)         REFERENCES dbo.Dim_Date (DateKey),
    CONSTRAINT FK_Fact_Invoice_LastPayDate FOREIGN KEY (LastPaymentDateKey) REFERENCES dbo.Dim_Date (DateKey),
    CONSTRAINT FK_Fact_Invoice_Contract    FOREIGN KEY (ContractKey)        REFERENCES dbo.Dim_Contract (ContractKey),
    CONSTRAINT FK_Fact_Invoice_Tenant      FOREIGN KEY (TenantKey)          REFERENCES dbo.Dim_Tenant (TenantKey),
    CONSTRAINT FK_Fact_Invoice_Premises    FOREIGN KEY (PremisesKey)        REFERENCES dbo.Dim_Premises (PremisesKey),
    CONSTRAINT FK_Fact_Invoice_Status      FOREIGN KEY (StatusKey)          REFERENCES dbo.Dim_InvoiceStatus (StatusKey)
);
GO

-- Платежі: один рядок = один платіж
CREATE TABLE dbo.Fact_Payment
(
    PaymentID       INT            NOT NULL,
    InvoiceID       INT            NOT NULL,   -- вироджений вимір
    PaymentDateKey  INT            NOT NULL,
    DueDateKey      INT            NOT NULL,
    ContractKey     INT            NOT NULL,
    TenantKey       INT            NOT NULL,
    PremisesKey     INT            NOT NULL,
    Amount          DECIMAL(12,2)  NOT NULL,
    DaysLate        INT            NOT NULL,   -- від'ємне — оплачено до терміну
    PaymentTiming   NVARCHAR(20)   NOT NULL,   -- Наперед / Вчасно / Із запізненням
    RunID           INT            NOT NULL,
    CONSTRAINT PK_Fact_Payment PRIMARY KEY CLUSTERED (PaymentID),
    CONSTRAINT FK_Fact_Payment_PaymentDate FOREIGN KEY (PaymentDateKey) REFERENCES dbo.Dim_Date (DateKey),
    CONSTRAINT FK_Fact_Payment_DueDate     FOREIGN KEY (DueDateKey)     REFERENCES dbo.Dim_Date (DateKey),
    CONSTRAINT FK_Fact_Payment_Contract    FOREIGN KEY (ContractKey)    REFERENCES dbo.Dim_Contract (ContractKey),
    CONSTRAINT FK_Fact_Payment_Tenant      FOREIGN KEY (TenantKey)      REFERENCES dbo.Dim_Tenant (TenantKey),
    CONSTRAINT FK_Fact_Payment_Premises    FOREIGN KEY (PremisesKey)    REFERENCES dbo.Dim_Premises (PremisesKey)
);
GO

-- Завантаженість: помісячний знімок (приміщення × місяць), включно з місяцями без оренди
CREATE TABLE dbo.Fact_Occupancy
(
    PremisesKey     INT            NOT NULL,
    MonthDateKey    INT            NOT NULL,   -- перше число місяця, yyyymmdd
    RentedDays      INT            NOT NULL,
    DaysInMonth     INT            NOT NULL,
    OccupancyRate   DECIMAL(5,4)   NOT NULL,   -- 0..1
    ContractsCount  INT            NOT NULL,
    RentIncome      DECIMAL(14,2)  NOT NULL,   -- нарахована оренда за місяць
    RunID           INT            NOT NULL,
    CONSTRAINT PK_Fact_Occupancy PRIMARY KEY CLUSTERED (MonthDateKey, PremisesKey),
    CONSTRAINT FK_Fact_Occupancy_Month    FOREIGN KEY (MonthDateKey) REFERENCES dbo.Dim_Date (DateKey),
    CONSTRAINT FK_Fact_Occupancy_Premises FOREIGN KEY (PremisesKey)  REFERENCES dbo.Dim_Premises (PremisesKey)
);
GO

-- Індекси під з'єднання з вимірами (куб, звіти)
CREATE NONCLUSTERED INDEX IX_Fact_Invoice_Period   ON dbo.Fact_Invoice (PeriodDateKey);
CREATE NONCLUSTERED INDEX IX_Fact_Invoice_Tenant   ON dbo.Fact_Invoice (TenantKey);
CREATE NONCLUSTERED INDEX IX_Fact_Invoice_Premises ON dbo.Fact_Invoice (PremisesKey);
CREATE NONCLUSTERED INDEX IX_Fact_Invoice_IsPaid   ON dbo.Fact_Invoice (IsPaid) INCLUDE (InvoiceID);
CREATE NONCLUSTERED INDEX IX_Fact_Payment_Date     ON dbo.Fact_Payment (PaymentDateKey);
CREATE NONCLUSTERED INDEX IX_Fact_Payment_Tenant   ON dbo.Fact_Payment (TenantKey);
CREATE NONCLUSTERED INDEX IX_Fact_Occupancy_Prem   ON dbo.Fact_Occupancy (PremisesKey);
GO

/* =====================================================================
   STAGING для SCD: змінені рядки вимірів, які потім застосовують процедури
   ===================================================================== */
CREATE TABLE dbo.Stage_Tenant
(
    TenantID    INT            NOT NULL,
    Name        NVARCHAR(150)  NOT NULL,
    TenantType  NVARCHAR(50)   NOT NULL,
    TaxCode     NVARCHAR(10)   NOT NULL,
    Phone       NVARCHAR(13)   NOT NULL,
    Email       NVARCHAR(100)  NOT NULL,
    HasEmail    BIT            NOT NULL
);

CREATE TABLE dbo.Stage_Premises
(
    PremisesID     INT            NOT NULL,
    City           NVARCHAR(50)   NOT NULL,
    Address        NVARCHAR(200)  NOT NULL,
    Floor          SMALLINT       NULL,
    FloorCategory  NVARCHAR(30)   NOT NULL,
    RoomsCount     SMALLINT       NOT NULL,
    Area           DECIMAL(9,2)   NOT NULL,
    AreaCategory   NVARCHAR(30)   NOT NULL,
    PremisesType   NVARCHAR(100)  NOT NULL,
    TypeGroup      NVARCHAR(50)   NOT NULL,
    MonthlyPrice   DECIMAL(12,2)  NOT NULL
);

CREATE TABLE dbo.Stage_Contract
(
    ContractID        INT            NOT NULL,
    TerminationDate   DATETIME       NULL,
    EffectiveEndDate  DATETIME       NOT NULL,
    DurationMonths    INT            NOT NULL,
    DurationCategory  NVARCHAR(30)   NOT NULL,
    IsTerminated      BIT            NOT NULL
);
GO

/* =====================================================================
   ТАБЛИЦІ АУДИТУ ETL
   ===================================================================== */

-- Запуски ETL: режим, час, статус і watermark-и для інкрементального завантаження
CREATE TABLE dbo.ETL_Audit
(
    RunID          INT IDENTITY(1,1) NOT NULL,
    RequestedMode  NVARCHAR(20)      NOT NULL,   -- що вказано в параметрі LoadMode
    LoadMode       NVARCHAR(20)      NOT NULL,   -- що фактично виконано
    StartTime      DATETIME          NOT NULL CONSTRAINT DF_ETL_Audit_Start DEFAULT (SYSDATETIME()),
    EndTime        DATETIME          NULL,
    Status         NVARCHAR(20)      NOT NULL,   -- Running / Success / Warning / Failed
    LastInvoiceID  INT               NULL,       -- watermark після запуску
    LastPaymentID  INT               NULL,
    Message        NVARCHAR(4000)    NULL,
    CONSTRAINT PK_ETL_Audit PRIMARY KEY CLUSTERED (RunID),
    CONSTRAINT CK_ETL_Audit_Status CHECK (Status IN (N'Running', N'Success', N'Warning', N'Failed'))
);

-- Кількість оброблених рядків по кожній таблиці в кожному запуску
CREATE TABLE dbo.ETL_RowCount
(
    ID            INT IDENTITY(1,1) NOT NULL,
    RunID         INT               NOT NULL,
    TableName     NVARCHAR(100)     NOT NULL,
    RowsInserted  INT               NOT NULL,
    RowsUpdated   INT               NOT NULL,
    RowsError     INT               NOT NULL,
    LoggedAt      DATETIME          NOT NULL CONSTRAINT DF_ETL_RowCount_LoggedAt DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_ETL_RowCount PRIMARY KEY CLUSTERED (ID),
    CONSTRAINT FK_ETL_RowCount_Audit FOREIGN KEY (RunID) REFERENCES dbo.ETL_Audit (RunID)
);

-- Відбраковані рядки (не знайдено ключ виміру, некоректні суми тощо)
CREATE TABLE dbo.ETL_ErrorRow
(
    ID           INT IDENTITY(1,1) NOT NULL,
    RunID        INT               NOT NULL,
    SourceTable  NVARCHAR(50)      NOT NULL,
    BusinessKey  INT               NOT NULL,
    ErrorReason  NVARCHAR(200)     NOT NULL,
    LoggedAt     DATETIME          NOT NULL CONSTRAINT DF_ETL_ErrorRow_LoggedAt DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_ETL_ErrorRow PRIMARY KEY CLUSTERED (ID)
);

-- Помилки виконання пакета (пише Event Handler OnError)
CREATE TABLE dbo.ETL_ErrorLog
(
    ID                INT IDENTITY(1,1) NOT NULL,
    RunID             INT               NULL,
    SourceName        NVARCHAR(200)     NOT NULL,
    ErrorCode         INT               NOT NULL,
    ErrorDescription  NVARCHAR(4000)    NOT NULL,
    LoggedAt          DATETIME          NOT NULL CONSTRAINT DF_ETL_ErrorLog_LoggedAt DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_ETL_ErrorLog PRIMARY KEY CLUSTERED (ID)
);
GO

PRINT N'Таблиці сховища створено.';
GO
