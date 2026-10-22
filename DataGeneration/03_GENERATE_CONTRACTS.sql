USE [Rental];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Rows INT;

IF EXISTS (SELECT 1 FROM dbo.Contract)
BEGIN
    ;THROW 51003, N'Таблиця Contract не порожня. Спочатку виконайте 00_CLEAR_DATA.sql.', 1;
END;
IF NOT EXISTS (SELECT 1 FROM dbo.Premises) OR NOT EXISTS (SELECT 1 FROM dbo.Tenant)
BEGIN
    ;THROW 51004, N'Спочатку згенеруйте приміщення (01) та орендарів (02).', 1;
END;

DECLARE @HistoryStart     DATE = '2021-11-01';   -- початок 5-річної історії
DECLARE @HistoryEnd       DATE = '2026-10-22';   -- «сьогодні» для згенерованих даних
DECLARE @TargetContracts  INT  = 100000;
DECLARE @MaxChain         INT  = 60;             -- максимум договорів на одне приміщення
DECLARE @YearlyGrowth     FLOAT = 1.10;          -- ціни оренди зростають на 10 % за рік

DECLARE @LastMonth DATE = DATEFROMPARTS(YEAR(@HistoryEnd), MONTH(@HistoryEnd), 1);

/* =====================================================================
   1. Профіль оренди приміщення за його типом
      S — короткострокова (конференц-зали, коворкінги, фотостудії): 1–2 місяці, часто частина місяця
      L — довгострокова (склади, виробничі приміщення): 3–12 місяців
      R — житлова (квартири, будинки): від 1 місяця до року
      N — звичайна (решта): 1–12 місяців, переважно короткі
      Житло (квартири, будинки, кімнати) орендують фізичні особи,
      решту приміщень — ФОП і юридичні особи.
   ===================================================================== */
SELECT
    p.PremisesID,
    p.MonthlyPrice,
    CASE WHEN pt.Name IN (N'Конференц-зал', N'Коворкінг', N'Фотостудія') THEN 'S'
         WHEN pt.Name IN (N'Склад', N'Виробниче приміщення')             THEN 'L'
         WHEN pt.Name IN (N'Квартира', N'Будинок')                        THEN 'R'
         ELSE 'N' END AS Profile,
    CASE WHEN pt.Name IN (N'Квартира', N'Будинок', N'Кімната') THEN 1 ELSE 0 END AS IsResidential
INTO #Prem
FROM dbo.Premises AS p
JOIN dbo.PremisesType AS pt ON pt.TypeID = p.TypeID;

/* =====================================================================
   2. Ланцюжок договорів для кожного приміщення:
      пауза (місяців без оренди) → договір на N місяців → пауза → договір …
      Кожен договір займає цілі «слоти» місяців, тому договори одного
      приміщення ніколи не перетинаються.
   ===================================================================== */
WITH Seq AS (
    SELECT TOP (@MaxChain) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS Seq
    FROM sys.all_objects
)
SELECT
    p.PremisesID,
    p.Profile,
    p.IsResidential,
    p.MonthlyPrice,
    s.Seq,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100   AS rGap,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100   AS rDuration,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100   AS rMidMonth,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100   AS rTerminate,
    ABS(CHECKSUM(NEWID()) % 1000000)         AS rDay,
    ABS(CHECKSUM(NEWID()) % 1000000)         AS rSign,
    ABS(CHECKSUM(NEWID()) % 1000000)         AS rTermMonth,
    ABS(CHECKSUM(NEWID()) % 1000000) / 1000000.0 AS rRent,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100   AS rDeposit,
    ABS(CHECKSUM(NEWID()) % 1000000) % 6 + 1 AS PaymentDayIdx
INTO #Cand
FROM #Prem AS p
CROSS JOIN Seq AS s;

-- Пауза перед договором і тривалість договору (у місяцях) за профілем
SELECT
    c.*,
    CASE
        WHEN c.Seq = 1 THEN c.rGap % 3                                   -- перший договір: 0–2 міс.
        WHEN c.Profile = 'S' THEN CASE WHEN c.rGap < 55 THEN 0 WHEN c.rGap < 90 THEN 1 ELSE 2 END
        WHEN c.Profile = 'L' THEN CASE WHEN c.rGap < 40 THEN 0 WHEN c.rGap < 75 THEN 1 ELSE 2 END
        WHEN c.Profile = 'R' THEN CASE WHEN c.rGap < 60 THEN 0 WHEN c.rGap < 88 THEN 1 WHEN c.rGap < 96 THEN 2 ELSE 3 END
        ELSE CASE WHEN c.rGap < 62 THEN 0 WHEN c.rGap < 92 THEN 1 WHEN c.rGap < 98 THEN 2 ELSE 3 END
    END AS Gap,
    CASE
        WHEN c.Profile = 'S' THEN CASE WHEN c.rDuration < 90 THEN 1 ELSE 2 END
        WHEN c.Profile = 'L' THEN CASE WHEN c.rDuration < 20 THEN 3 WHEN c.rDuration < 60 THEN 6 ELSE 12 END
        WHEN c.Profile = 'R' THEN CASE WHEN c.rDuration < 45 THEN 1 WHEN c.rDuration < 60 THEN 2
                                       WHEN c.rDuration < 75 THEN 3 WHEN c.rDuration < 90 THEN 6 ELSE 12 END
        ELSE CASE WHEN c.rDuration < 52 THEN 1 WHEN c.rDuration < 74 THEN 2
                  WHEN c.rDuration < 87 THEN 3 WHEN c.rDuration < 96 THEN 6 ELSE 12 END
    END AS Duration
INTO #Chain
FROM #Cand AS c;

-- Зсув початку договору від @HistoryStart = сума попередніх (пауза + тривалість) + власна пауза
SELECT
    ch.*,
    SUM(ch.Gap + ch.Duration) OVER (PARTITION BY ch.PremisesID ORDER BY ch.Seq
                                    ROWS UNBOUNDED PRECEDING) - ch.Duration AS StartOffset
INTO #Slots
FROM #Chain AS ch;

/* =====================================================================
   3. Дати договорів
      • 50 % короткострокових договорів на 1 місяць — оренда на 3–11 днів;
      • частина договорів починається не з 1-го числа (15 %, для S — 40 %);
      • договір закінчується в останній день свого останнього місяця;
      • 6 % договорів від 3 місяців достроково розірвані (лише в минулому);
      • підписання — за 1–20 днів до початку оренди.
   ===================================================================== */
SELECT
    s.*,
    DATEADD(MONTH, s.StartOffset, @HistoryStart) AS StartMonth
INTO #Dated0
FROM #Slots AS s
WHERE DATEADD(MONTH, s.StartOffset, @HistoryStart) <= @LastMonth;

SELECT
    d.*,
    CASE
        WHEN d.Profile = 'S' AND d.Duration = 1 AND d.rMidMonth < 50
            THEN DATEADD(DAY, d.rDay % 20, d.StartMonth)                       -- 1–20 число
        WHEN d.rMidMonth < CASE WHEN d.Profile = 'S' THEN 40 ELSE 15 END
            THEN DATEADD(DAY, 1 + d.rDay % 26, d.StartMonth)                   -- 2–27 число
        ELSE d.StartMonth
    END AS StartDate,
    CASE WHEN d.Profile = 'S' AND d.Duration = 1 AND d.rMidMonth < 50
         THEN 1 ELSE 0 END AS IsShortStay
INTO #Dated1
FROM #Dated0 AS d;

SELECT
    d.*,
    CASE WHEN d.IsShortStay = 1
         THEN LEAST(DATEADD(DAY, 2 + d.rDay % 9, d.StartDate), EOMONTH(d.StartMonth))
         ELSE EOMONTH(d.StartMonth, d.Duration - 1)
    END AS EndDate,
    DATEADD(DAY, -(1 + d.rSign % 20), d.StartDate) AS SignDate,
    CASE WHEN d.Duration >= 3 AND d.rTerminate < 6
         THEN EOMONTH(d.StartMonth, d.rTermMonth % (d.Duration - 1))
    END AS TerminationCandidate
INTO #Dated
FROM #Dated1 AS d;

-- Розірвання лише в минулому; договори, підписані «в майбутньому», не беремо
SELECT
    d.*,
    CASE WHEN d.TerminationCandidate < @HistoryEnd THEN d.TerminationCandidate END AS TerminationDate
INTO #All
FROM #Dated AS d
WHERE d.SignDate <= @HistoryEnd;

SELECT @Rows = COUNT(*) FROM #All;
RAISERROR(N'Кандидатів у договори: %d', 0, 1, @Rows) WITH NOWAIT;

IF @Rows < @TargetContracts
BEGIN
    ;THROW 51005, N'Кандидатів менше за цільову кількість договорів — зменшіть паузи або збільшіть @MaxChain.', 1;
END;

/* =====================================================================
   4. Рівно @TargetContracts договорів: зайві видаляються випадково
      (це лише додає пауз між договорами, перетинів не з'являється)
   ===================================================================== */
SELECT TOP (@TargetContracts)
    a.*,
    ABS(CHECKSUM(NEWID()) % 1000000) / 1000000.0 AS rTenant
INTO #Kept
FROM #All AS a
ORDER BY NEWID();

/* =====================================================================
   5. Орендарі
      Житло → фізичні особи, решта → ФОП і юридичні особи.
      У межах кожної групи кожен орендар отримує щонайменше один договір,
      решта договорів розподіляється з перекосом на «постійних клієнтів».
   ===================================================================== */
SELECT
    TenantID,
    CASE WHEN TenantTypeID = 1 THEN 1 ELSE 0 END AS IsResidential,
    ROW_NUMBER() OVER (PARTITION BY CASE WHEN TenantTypeID = 1 THEN 1 ELSE 0 END
                       ORDER BY TenantID) AS TenantIdx
INTO #Tenants
FROM dbo.Tenant;

SELECT IsResidential, COUNT(*) AS TenantCount
INTO #TenantGroup
FROM #Tenants
GROUP BY IsResidential;

SELECT
    k.*,
    ROW_NUMBER() OVER (PARTITION BY k.IsResidential ORDER BY NEWID()) AS AssignOrder
INTO #Assign
FROM #Kept AS k;

IF EXISTS (
    SELECT 1
    FROM #TenantGroup AS g
    WHERE g.TenantCount > (SELECT COUNT(*) FROM #Assign AS a WHERE a.IsResidential = g.IsResidential)
)
BEGIN
    ;THROW 51006, N'У групі (житло / комерція) орендарів більше, ніж договорів.', 1;
END;

/* =====================================================================
   6. Вставка договорів (у хронологічному порядку)
      Ціна: поточна ціна приміщення, «повернена» в минуле на 10 % за рік, ±5 %.
      Тригер TR_Contract_Validate лишається увімкненим і перевіряє,
      що договори одного приміщення не перетинаються.
   ===================================================================== */
WITH X AS (
    SELECT
        a.*,
        t.TenantID,
        CAST(ROUND(a.MonthlyPrice
                   / POWER(@YearlyGrowth, DATEDIFF(DAY, a.StartDate, @HistoryEnd) / 365.25)
                   * (0.95 + a.rRent * 0.10), -1) AS DECIMAL(12,2)) AS MonthlyRent,
        ROW_NUMBER() OVER (ORDER BY a.StartDate, a.PremisesID) AS ContractNo
    FROM #Assign AS a
    JOIN #TenantGroup AS g ON g.IsResidential = a.IsResidential
    JOIN #Tenants AS t
      ON  t.IsResidential = a.IsResidential
      AND t.TenantIdx = CASE WHEN a.AssignOrder <= g.TenantCount
                             THEN a.AssignOrder
                             ELSE 1 + CAST(FLOOR(g.TenantCount * a.rTenant * a.rTenant) AS INT) END
)
INSERT INTO dbo.Contract
    (ContractNumber, TenantID, PremisesID, SignDate, StartDate, EndDate,
     TerminationDate, MonthlyRent, Deposit, PaymentDay)
SELECT
    CONCAT('CN-', YEAR(SignDate), '-', RIGHT(CONCAT('0000000', ContractNo), 7)),
    TenantID,
    PremisesID,
    SignDate,
    StartDate,
    EndDate,
    TerminationDate,
    MonthlyRent,
    CASE WHEN Profile = 'S'    THEN 0
         WHEN Profile = 'R'    THEN CASE WHEN rDeposit < 70 THEN MonthlyRent ELSE MonthlyRent * 2 END
         WHEN rDeposit < 60    THEN MonthlyRent
         WHEN rDeposit < 75    THEN MonthlyRent * 2
         ELSE 0 END,
    CHOOSE(PaymentDayIdx, 1, 5, 10, 15, 20, 25)
FROM X
ORDER BY ContractNo;

SET @Rows = @@ROWCOUNT;
RAISERROR(N'Contract: %d', 0, 1, @Rows) WITH NOWAIT;

DROP TABLE #Prem, #Cand, #Chain, #Slots, #Dated0, #Dated1, #Dated, #All, #Kept, #Tenants, #TenantGroup, #Assign;
GO
