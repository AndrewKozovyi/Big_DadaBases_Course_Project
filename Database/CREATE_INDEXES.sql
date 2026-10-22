USE [Rental];
GO

/* ---------- Premises ---------- */
DROP INDEX IF EXISTS IX_Premises_TypeID ON dbo.Premises;
CREATE NONCLUSTERED INDEX IX_Premises_TypeID
    ON dbo.Premises (TypeID);

-- Фільтр «місто» у звітах про стан і завантаженість приміщень
DROP INDEX IF EXISTS IX_Premises_City ON dbo.Premises;
CREATE NONCLUSTERED INDEX IX_Premises_City
    ON dbo.Premises (City) INCLUDE (TypeID, Area);
GO

/* ---------- Tenant ---------- */
DROP INDEX IF EXISTS IX_Tenant_TenantTypeID ON dbo.Tenant;
CREATE NONCLUSTERED INDEX IX_Tenant_TenantTypeID
    ON dbo.Tenant (TenantTypeID);
GO

/* ---------- Contract ---------- */
-- Перевірка перетину періодів оренди (тригер) і «стан приміщень на дату»
DROP INDEX IF EXISTS IX_Contract_Premises_Period ON dbo.Contract;
CREATE NONCLUSTERED INDEX IX_Contract_Premises_Period
    ON dbo.Contract (PremisesID, StartDate)
    INCLUDE (EndDate, TerminationDate, TenantID);

-- Історія оренди і борги конкретного орендаря
DROP INDEX IF EXISTS IX_Contract_TenantID ON dbo.Contract;
CREATE NONCLUSTERED INDEX IX_Contract_TenantID
    ON dbo.Contract (TenantID)
    INCLUDE (PremisesID, StartDate, EndDate, TerminationDate);
GO

/* ---------- Invoice ---------- */
-- Пошук рахунків договору вже покриває індекс обмеження UQ_Invoice_Contract_Period
-- Пошук неоплачених / прострочених рахунків
DROP INDEX IF EXISTS IX_Invoice_StatusID_DueDate ON dbo.Invoice;
CREATE NONCLUSTERED INDEX IX_Invoice_StatusID_DueDate
    ON dbo.Invoice (StatusID, DueDate)
    INCLUDE (ContractID, TotalAmount);

-- Фінансові звіти за період
DROP INDEX IF EXISTS IX_Invoice_IssueDate ON dbo.Invoice;
CREATE NONCLUSTERED INDEX IX_Invoice_IssueDate
    ON dbo.Invoice (IssueDate)
    INCLUDE (ContractID, StatusID, RentAmount, UtilitiesAmount, PenaltyAmount, TotalAmount);
GO

/* ---------- Payment ---------- */
-- Сума оплат по рахунку (тригер перерахунку статусу)
DROP INDEX IF EXISTS IX_Payment_InvoiceID ON dbo.Payment;
CREATE NONCLUSTERED INDEX IX_Payment_InvoiceID
    ON dbo.Payment (InvoiceID)
    INCLUDE (Amount, PaymentDate);

-- Надходження коштів за період
DROP INDEX IF EXISTS IX_Payment_PaymentDate ON dbo.Payment;
CREATE NONCLUSTERED INDEX IX_Payment_PaymentDate
    ON dbo.Payment (PaymentDate)
    INCLUDE (InvoiceID, Amount);
GO

PRINT N'Індекси створено.';
GO
