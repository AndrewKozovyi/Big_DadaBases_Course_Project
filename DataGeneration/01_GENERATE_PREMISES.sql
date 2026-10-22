USE [Rental];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Rows INT;

IF EXISTS (SELECT 1 FROM dbo.PremisesType) OR EXISTS (SELECT 1 FROM dbo.Premises)
BEGIN
    ;THROW 51001, N'Таблиці PremisesType / Premises не порожні. Спочатку виконайте 00_CLEAR_DATA.sql.', 1;
END;

DECLARE @PremisesCount INT = 5000;

-- Випадкові числа: ABS(CHECKSUM(NEWID()) % 1000000) — рівномірне ціле 0..999999
-- (спершу остача, потім ABS — так немає переповнення на мінімальному INT).
-- Значення, що використовуються кілька разів, спершу зберігаються в #-таблицю,
-- бо NEWID() у CTE обчислюється заново при кожному зверненні.

/* ---------- Типи приміщень: ставка 2026 р., діапазони площі, кімнат і поверхів, частка ---------- */
DECLARE @Type TABLE
(
    TypeNo         INT            PRIMARY KEY,
    Name           NVARCHAR(100)  NOT NULL,
    RatePerM2      DECIMAL(8,2)   NOT NULL,   -- грн за м² на місяць
    AreaMin        INT            NOT NULL,
    AreaMax        INT            NOT NULL,
    RoomsMin       INT            NOT NULL,
    RoomsMax       INT            NOT NULL,
    FloorMin       INT            NULL,       -- NULL — окремий об'єкт без поверху (будинок)
    FloorMax       INT            NULL,       -- від'ємні — підземні поверхи, 0 — цокольний
    SharePct       INT            NOT NULL,   -- частка серед усіх приміщень, % (сума = 100)
    AddressSuffix  NVARCHAR(20)   NULL        -- що дописується до адреси перед номером приміщення
);
INSERT INTO @Type VALUES
    ( 1, N'Квартира',              400,  25,  120, 1,  4,    1, 25, 22, N'кв.'),
    ( 2, N'Будинок',               300,  80,  300, 3,  8, NULL, NULL, 4, NULL),
    ( 3, N'Кімната',               450,  10,   25, 1,  1,    1, 16,  4, N'кімн.'),
    ( 4, N'Офіс',                  450,  15,  300, 1, 10,    1, 30, 18, N'оф.'),
    ( 5, N'Коворкінг',             800,  10,   60, 1,  2,    1, 20,  6, N'оф.'),
    ( 6, N'Конференц-зал',         700,  30,  200, 1,  3,    1, 20,  5, N'оф.'),
    ( 7, N'Торгове приміщення',    600,  30,  500, 1,  5,    1,  3,  9, N'прим.'),
    ( 8, N'Кафе',                  550,  50,  300, 2,  6,    1,  2,  4, N'прим.'),
    ( 9, N'Шоурум',                500,  50,  400, 1,  4,    1,  2,  2, N'прим.'),
    (10, N'Салон краси',           500,  30,  120, 2,  6,    1,  3,  3, N'прим.'),
    (11, N'Медичний кабінет',      520,  15,   80, 1,  4,    1,  5,  3, N'оф.'),
    (12, N'Фотостудія',            600,  30,  150, 1,  3,    1, 10,  3, N'оф.'),
    (13, N'Спортзал',              350, 100,  600, 2,  6,   -1,  3,  2, N'прим.'),
    (14, N'Склад',                 150, 100, 2000, 1,  4,   -1,  1,  7, N'прим.'),
    (15, N'Виробниче приміщення',  180, 200, 3000, 2, 10,    1,  2,  2, N'прим.'),
    (16, N'Майстерня',             300,  20,  150, 1,  3,   -1,  1,  2, N'прим.'),
    (17, N'Гараж',                 180,  15,   40, 1,  1,   -1,  1,  2, N'гараж'),
    (18, N'Паркомісце',            150,  12,   18, 1,  1,   -3, -1,  2, N'паркомісце');

/* ---------- Міста: коефіцієнт ціни та частка приміщень ---------- */
DECLARE @City TABLE
(
    CityID     INT           PRIMARY KEY,
    Name       NVARCHAR(50)  NOT NULL,
    PriceCoef  DECIMAL(4,2)  NOT NULL,
    SharePct   INT           NOT NULL    -- сума = 100
);
INSERT INTO @City VALUES
    ( 1, N'Київ',             1.50, 30),
    ( 2, N'Львів',            1.20, 15),
    ( 3, N'Харків',           0.90, 10),
    ( 4, N'Одеса',            1.10, 10),
    ( 5, N'Дніпро',           1.00, 10),
    ( 6, N'Запоріжжя',        0.80,  5),
    ( 7, N'Вінниця',          0.85,  5),
    ( 8, N'Івано-Франківськ', 0.90,  5),
    ( 9, N'Тернопіль',        0.80,  5),
    (10, N'Ужгород',          0.85,  5);

/* ---------- Вулиці ---------- */
DECLARE @Street TABLE (StreetID INT IDENTITY(1,1) PRIMARY KEY, Name NVARCHAR(60) NOT NULL);
INSERT INTO @Street (Name) VALUES
    (N'вул. Шевченка'), (N'вул. Івана Франка'), (N'вул. Лесі Українки'), (N'вул. Грушевського'),
    (N'просп. Свободи'), (N'просп. Незалежності'), (N'вул. Соборна'), (N'вул. Героїв Майдану'),
    (N'вул. Садова'), (N'вул. Центральна'), (N'вул. Січових Стрільців'), (N'вул. Богдана Хмельницького'),
    (N'вул. Котляревського'), (N'вул. Григорія Сковороди'), (N'вул. Миру'), (N'вул. Зелена'),
    (N'вул. Набережна'), (N'вул. Київська'), (N'вул. Михайла Коцюбинського'), (N'вул. Ярослава Мудрого'),
    (N'вул. Володимира Великого'), (N'вул. Гетьмана Мазепи'), (N'вул. Ольги Кобилянської'), (N'вул. Василя Стуса'),
    (N'вул. Промислова'), (N'вул. Індустріальна'), (N'вул. Складська'), (N'вул. Заводська'),
    (N'вул. Університетська'), (N'вул. Театральна');
DECLARE @StreetCount INT = (SELECT COUNT(*) FROM @Street);

/* =====================================================================
   1. Типи приміщень
   ===================================================================== */
INSERT INTO dbo.PremisesType (Name)
SELECT Name
FROM @Type
ORDER BY TypeNo;

SET @Rows = @@ROWCOUNT;
RAISERROR(N'PremisesType: %d', 0, 1, @Rows) WITH NOWAIT;

-- Накопичувальні межі часток для зваженого випадкового вибору (0..99)
SELECT t.*,
       pt.TypeID,
       SUM(t.SharePct) OVER (ORDER BY t.TypeNo) - t.SharePct AS CumFrom,
       SUM(t.SharePct) OVER (ORDER BY t.TypeNo)              AS CumTo
INTO #Type
FROM @Type AS t
JOIN dbo.PremisesType AS pt ON pt.Name = t.Name;

SELECT ci.*,
       SUM(ci.SharePct) OVER (ORDER BY ci.CityID) - ci.SharePct AS CumFrom,
       SUM(ci.SharePct) OVER (ORDER BY ci.CityID)               AS CumTo
INTO #City
FROM @City AS ci;

/* =====================================================================
   2. Випадкові параметри для кожного приміщення
   ===================================================================== */
WITH N AS (
    SELECT TOP (@PremisesCount) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
)
SELECT
    n,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100              AS rType,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100              AS rCity,
    ABS(CHECKSUM(NEWID()) % 1000000) % @StreetCount + 1 AS StreetID,
    ABS(CHECKSUM(NEWID()) % 1000000) % 150              AS rHouse,
    ABS(CHECKSUM(NEWID()) % 1000000) / 1000000.0        AS rArea,    -- 0..1
    ABS(CHECKSUM(NEWID()) % 1000000) / 1000000.0        AS rFloor,   -- 0..1
    0.85 + ABS(CHECKSUM(NEWID()) % 1000000) / 3333333.0 AS rPrice    -- 0.85..1.15
INTO #Rnd
FROM N;

/* =====================================================================
   3. Приміщення
      Площа: ближче до мінімуму типу (квадрат випадкового числа).
      Кімнати: пропорційно площі.
      Поверх: рівномірно в межах типу; у будинку поверху немає (NULL).
      Ціна: площа × ставка типу × коеф. міста × ±15 %, округлена до 10 грн.
      Адреса: будинки мають номери 151–300 (за збігу — «12/2»),
      решта — номер будинку 1–150 + «кв. / оф. / прим. …» з номером,
      унікальним у межах будинку.
   ===================================================================== */
WITH P AS (
    SELECT
        r.n,
        t.TypeID,
        t.AddressSuffix,
        ci.Name                         AS CityName,
        s.Name                          AS StreetName,
        CASE WHEN t.AddressSuffix IS NULL THEN 151 ELSE 1 END + r.rHouse AS House,
        r.rArea,
        t.RoomsMin,
        t.RoomsMax,
        CASE WHEN t.FloorMin IS NOT NULL
             THEN t.FloorMin + CAST(FLOOR((t.FloorMax - t.FloorMin + 1) * r.rFloor) AS INT)
        END                             AS Floor,
        CAST(ROUND(t.AreaMin + (t.AreaMax - t.AreaMin) * r.rArea * r.rArea, 1) AS DECIMAL(9,2)) AS Area,
        t.RatePerM2 * ci.PriceCoef * r.rPrice AS RateFinal
    FROM #Rnd AS r
    JOIN #Type AS t     ON r.rType >= t.CumFrom AND r.rType < t.CumTo
    JOIN #City AS ci    ON r.rCity >= ci.CumFrom AND r.rCity < ci.CumTo
    JOIN @Street AS s   ON s.StreetID = r.StreetID
),
Numbered AS (
    SELECT
        P.*,
        ROW_NUMBER() OVER (PARTITION BY CityName, StreetName, House, AddressSuffix ORDER BY n) AS UnitNo
    FROM P
)
INSERT INTO dbo.Premises (TypeID, City, Address, Floor, RoomsCount, Area, MonthlyPrice)
SELECT
    TypeID,
    CityName,
    CASE WHEN AddressSuffix IS NULL
         THEN CONCAT(StreetName, N', ', House, CASE WHEN UnitNo > 1 THEN CONCAT(N'/', UnitNo) END)
         ELSE CONCAT(StreetName, N', ', House, N', ', AddressSuffix, N' ', UnitNo)
    END,
    Floor,
    LEAST(RoomsMax, RoomsMin + CAST(FLOOR((RoomsMax - RoomsMin + 1) * rArea) AS INT)),
    Area,
    CAST(ROUND(Area * RateFinal, -1) AS DECIMAL(12,2))
FROM Numbered
ORDER BY n;

SET @Rows = @@ROWCOUNT;
RAISERROR(N'Premises: %d', 0, 1, @Rows) WITH NOWAIT;

DROP TABLE #Rnd, #Type, #City;
GO
