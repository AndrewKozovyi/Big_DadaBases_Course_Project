USE [RentalDW];
GO

SET NOCOUNT ON;

-- Державні свята України 2021–2027 для атрибута IsHoliday у Dim_Date.
-- Враховано зміни законодавства: з 2023 р. Різдво лише 25 грудня, День захисників 1 жовтня,
-- 8 травня замість 9 травня; День Української Державності з 2024 р. — 15 липня.
-- Великдень (за юліанським календарем) і Трійця (+49 днів) задані по роках.
-- (Під час воєнного стану свята не є вихідними; тут вони позначаються як календарні свята.)

DECLARE @Easter TABLE ([Year] INT PRIMARY KEY, EasterDate DATE NOT NULL);
INSERT INTO @Easter VALUES
    (2021, '2021-05-02'), (2022, '2022-04-24'), (2023, '2023-04-16'), (2024, '2024-05-05'),
    (2025, '2025-04-20'), (2026, '2026-04-12'), (2027, '2027-05-02');

DECLARE @Holiday TABLE (HolidayDate DATE PRIMARY KEY, HolidayName NVARCHAR(100) NOT NULL);

INSERT INTO @Holiday (HolidayDate, HolidayName)
SELECT h.HolidayDate, h.HolidayName
FROM @Easter AS e
CROSS APPLY (VALUES
    (DATEFROMPARTS(e.[Year], 1, 1),   N'Новий рік',                         1),
    (DATEFROMPARTS(e.[Year], 1, 7),   N'Різдво Христове (7 січня)',         CASE WHEN e.[Year] <= 2022 THEN 1 ELSE 0 END),
    (DATEFROMPARTS(e.[Year], 3, 8),   N'Міжнародний жіночий день',          1),
    (e.EasterDate,                    N'Великдень',                         1),
    (DATEFROMPARTS(e.[Year], 5, 1),   N'День праці',                        1),
    (DATEFROMPARTS(e.[Year], 5, 9),   N'День перемоги',                     CASE WHEN e.[Year] <= 2022 THEN 1 ELSE 0 END),
    (DATEFROMPARTS(e.[Year], 5, 8),   N'День пам''яті та перемоги',         CASE WHEN e.[Year] >= 2023 THEN 1 ELSE 0 END),
    (DATEADD(DAY, 49, e.EasterDate),  N'Трійця',                            1),
    (DATEFROMPARTS(e.[Year], 6, 28),  N'День Конституції України',          1),
    (DATEFROMPARTS(e.[Year], 7, 28),  N'День Української Державності',      CASE WHEN e.[Year] IN (2022, 2023) THEN 1 ELSE 0 END),
    (DATEFROMPARTS(e.[Year], 7, 15),  N'День Української Державності',      CASE WHEN e.[Year] >= 2024 THEN 1 ELSE 0 END),
    (DATEFROMPARTS(e.[Year], 8, 24),  N'День Незалежності України',         1),
    (DATEFROMPARTS(e.[Year], 10, 14), N'День захисників і захисниць',       CASE WHEN e.[Year] <= 2022 THEN 1 ELSE 0 END),
    (DATEFROMPARTS(e.[Year], 10, 1),  N'День захисників і захисниць',       CASE WHEN e.[Year] >= 2023 THEN 1 ELSE 0 END),
    (DATEFROMPARTS(e.[Year], 12, 25), N'Різдво Христове',                   1)
) AS h (HolidayDate, HolidayName, IsActive)
WHERE h.IsActive = 1;

MERGE dbo.Ref_Holiday AS target
USING @Holiday AS source
ON target.HolidayDate = source.HolidayDate
WHEN MATCHED THEN UPDATE SET HolidayName = source.HolidayName
WHEN NOT MATCHED BY TARGET THEN INSERT (HolidayDate, HolidayName) VALUES (source.HolidayDate, source.HolidayName)
WHEN NOT MATCHED BY SOURCE THEN DELETE;

SELECT YEAR(HolidayDate) AS [Year], COUNT(*) AS Holidays
FROM dbo.Ref_Holiday
GROUP BY YEAR(HolidayDate)
ORDER BY [Year];
GO
