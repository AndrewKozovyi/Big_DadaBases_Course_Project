USE [Rental];
GO

/* =====================================================================
   Тестування обмежень цілісності та тригерів бізнес-правил.
   Кожен тест намагається вставити некоректні дані в транзакції.
   Очікуваний результат — помилка у вкладці Messages; дані не змінюються
   (ROLLBACK). Лічильник IDENTITY таблиці може зрости на 1.
   ===================================================================== */

-- Тест 1: договір на приміщення, яке вже орендоване в цей період
-- Очікується: Msg 50001 від тригера TR_Contract_Validate
BEGIN TRAN;
INSERT INTO dbo.Contract (ContractNumber, TenantID, PremisesID, SignDate, StartDate, EndDate, MonthlyRent, Deposit, PaymentDay)
SELECT TOP (1) 'TEST-0001', TenantID, PremisesID, SignDate, StartDate, EndDate, MonthlyRent, 0, 10
FROM dbo.Contract ORDER BY ContractID;
ROLLBACK;
GO
IF @@TRANCOUNT > 0 ROLLBACK;
GO

-- Тест 2: телефон орендаря не у форматі +380XXXXXXXXX
-- Очікується: Msg 547, порушення CHECK-обмеження CK_Tenant_Phone
BEGIN TRAN;
INSERT INTO dbo.Tenant (TenantTypeID, Name, TaxCode, Phone, Email)
VALUES (1, N'Тестовий Орендар', '1234567899', '0671234567', NULL);
ROLLBACK;
GO
IF @@TRANCOUNT > 0 ROLLBACK;
GO
