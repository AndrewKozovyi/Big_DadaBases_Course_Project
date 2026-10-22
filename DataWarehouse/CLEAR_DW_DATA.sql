USE [RentalDW];
GO

SET NOCOUNT ON;

-- Очищає дані сховища без перестворення таблиць, процедур і довідника свят (Ref_Holiday лишається).
-- Факти видаляються раніше за виміри через зовнішні ключі.
DELETE FROM dbo.Fact_Occupancy;
DELETE FROM dbo.Fact_Payment;
DELETE FROM dbo.Fact_Invoice;

DELETE FROM dbo.Dim_Contract;
DELETE FROM dbo.Dim_Premises;
DELETE FROM dbo.Dim_Tenant;
DELETE FROM dbo.Dim_InvoiceStatus;
DELETE FROM dbo.Dim_Date;

TRUNCATE TABLE dbo.Stage_Tenant;
TRUNCATE TABLE dbo.Stage_Premises;
TRUNCATE TABLE dbo.Stage_Contract;

-- Журнали ETL: після очищення наступний запуск автоматично піде в режимі FULL
-- (usp_ETL_Start не знайде попереднього успішного запуску).
DELETE FROM dbo.ETL_RowCount;
DELETE FROM dbo.ETL_ErrorRow;
DELETE FROM dbo.ETL_ErrorLog;
DELETE FROM dbo.ETL_Audit;

-- Журнал SSIS log provider (таблицю створює сам SSIS при першому запуску)
IF OBJECT_ID(N'dbo.sysssislog', N'U') IS NOT NULL
    TRUNCATE TABLE dbo.sysssislog;

-- Сурогатні ключі знову починаються з 1
DBCC CHECKIDENT ('dbo.Dim_InvoiceStatus', RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('dbo.Dim_Tenant',        RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('dbo.Dim_Premises',      RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('dbo.Dim_Contract',      RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('dbo.ETL_Audit',         RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('dbo.ETL_RowCount',      RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('dbo.ETL_ErrorRow',      RESEED, 0) WITH NO_INFOMSGS;
DBCC CHECKIDENT ('dbo.ETL_ErrorLog',      RESEED, 0) WITH NO_INFOMSGS;

SELECT N'Fact_Invoice' AS TableName, COUNT(*) AS [Rows] FROM dbo.Fact_Invoice
UNION ALL SELECT N'Fact_Payment',   COUNT(*) FROM dbo.Fact_Payment
UNION ALL SELECT N'Fact_Occupancy', COUNT(*) FROM dbo.Fact_Occupancy
UNION ALL SELECT N'Dim_Date',       COUNT(*) FROM dbo.Dim_Date
UNION ALL SELECT N'Dim_Tenant',     COUNT(*) FROM dbo.Dim_Tenant
UNION ALL SELECT N'Dim_Premises',   COUNT(*) FROM dbo.Dim_Premises
UNION ALL SELECT N'Dim_Contract',   COUNT(*) FROM dbo.Dim_Contract
UNION ALL SELECT N'ETL_Audit',      COUNT(*) FROM dbo.ETL_Audit
UNION ALL SELECT N'Ref_Holiday',    COUNT(*) FROM dbo.Ref_Holiday;
GO
