USE [Rental];
GO

-- ID у цих довідниках фіксовані: на них спираються CHECK-обмеження
-- (CK_Tenant_TaxCode), тригери та процедури (статуси рахунків)

/* ---------- Типи орендарів ---------- */
MERGE dbo.TenantType AS target
USING (VALUES
    (1, N'Фізична особа'),
    (2, N'ФОП'),
    (3, N'Юридична особа')
) AS source (TenantTypeID, Name)
ON target.TenantTypeID = source.TenantTypeID
WHEN MATCHED THEN
    UPDATE SET Name = source.Name
WHEN NOT MATCHED BY TARGET THEN
    INSERT (TenantTypeID, Name) VALUES (source.TenantTypeID, source.Name);
GO

/* ---------- Статуси рахунків ---------- */
MERGE dbo.InvoiceStatus AS target
USING (VALUES
    (1, N'Не оплачено'),
    (2, N'Частково оплачено'),
    (3, N'Оплачено'),
    (4, N'Прострочено')
) AS source (StatusID, Name)
ON target.StatusID = source.StatusID
WHEN MATCHED THEN
    UPDATE SET Name = source.Name
WHEN NOT MATCHED BY TARGET THEN
    INSERT (StatusID, Name) VALUES (source.StatusID, source.Name);
GO

SELECT * FROM dbo.TenantType;
SELECT * FROM dbo.InvoiceStatus;
GO
