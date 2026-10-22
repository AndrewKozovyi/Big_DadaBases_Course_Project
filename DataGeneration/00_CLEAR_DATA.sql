USE [Rental];
GO

SET NOCOUNT ON;

-- Видалення всіх згенерованих даних у зворотному порядку залежностей.
-- Довідники з фіксованими ID (TenantType, InvoiceStatus) не чіпаємо.

-- Тригер на Payment при видаленні перераховував би статуси рахунків, які все одно видаляються
DISABLE TRIGGER TR_Payment_RecalcInvoice ON dbo.Payment;
DELETE FROM dbo.Payment;
ENABLE TRIGGER TR_Payment_RecalcInvoice ON dbo.Payment;

DELETE FROM dbo.Invoice;
DELETE FROM dbo.Contract;
DELETE FROM dbo.Tenant;
DELETE FROM dbo.Premises;
DELETE FROM dbo.PremisesType;

-- Лічильники IDENTITY знову з 1. Скидаємо лише ті, що вже використовувались:
-- для «свіжої» таблиці RESEED 0 дав би першому рядку ID = 0.
DECLARE @Table SYSNAME, @Sql NVARCHAR(300);

DECLARE TableCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name)
    FROM sys.identity_columns AS ic
    JOIN sys.tables AS t ON t.object_id = ic.object_id
    WHERE t.name IN (N'Payment', N'Invoice', N'Contract', N'Tenant', N'Premises', N'PremisesType')
      AND ic.last_value IS NOT NULL;

OPEN TableCursor;
FETCH NEXT FROM TableCursor INTO @Table;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'DBCC CHECKIDENT (''' + @Table + N''', RESEED, 0) WITH NO_INFOMSGS;';
    EXEC sys.sp_executesql @Sql;
    FETCH NEXT FROM TableCursor INTO @Table;
END;
CLOSE TableCursor;
DEALLOCATE TableCursor;

PRINT N'Дані очищено.';
GO
