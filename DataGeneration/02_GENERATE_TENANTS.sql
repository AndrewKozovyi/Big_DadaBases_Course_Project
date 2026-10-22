USE [Rental];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Rows INT;

IF EXISTS (SELECT 1 FROM dbo.Tenant)
BEGIN
    ;THROW 51002, N'Таблиця Tenant не порожня. Спочатку виконайте 00_CLEAR_DATA.sql.', 1;
END;

DECLARE @TenantCount INT = 50000;

-- Частки типів орендарів, %: 1 = Фізична особа, 2 = ФОП, 3 = Юридична особа
DECLARE @PctPerson INT = 25, @PctFop INT = 40;   -- юрособи = решта (35 %)

/* ---------- Чоловічі імена (з транслітерацією для email) ---------- */
DECLARE @MaleName TABLE (ID INT IDENTITY(1,1) PRIMARY KEY, Name NVARCHAR(30), Latin VARCHAR(30));
INSERT INTO @MaleName (Name, Latin) VALUES
    (N'Олександр','oleksandr'), (N'Андрій','andrii'), (N'Іван','ivan'), (N'Михайло','mykhailo'),
    (N'Дмитро','dmytro'), (N'Сергій','serhii'), (N'Володимир','volodymyr'), (N'Петро','petro'),
    (N'Максим','maksym'), (N'Юрій','yurii'), (N'Тарас','taras'), (N'Богдан','bohdan'),
    (N'Василь','vasyl'), (N'Віктор','viktor'), (N'Олег','oleh'), (N'Роман','roman'),
    (N'Ярослав','yaroslav'), (N'Остап','ostap'), (N'Микола','mykola'), (N'Павло','pavlo'),
    (N'Степан','stepan'), (N'Денис','denys'), (N'Владік','vladik'), (N'Назар','nazar'),
    (N'Ігор','ihor'), (N'Євген','yevhen'), (N'Олексій','oleksii'), (N'Вадим','vadym'),
    (N'Руслан','ruslan'), (N'Костянтин','kostiantyn');

/* ---------- Жіночі імена ---------- */
DECLARE @FemaleName TABLE (ID INT IDENTITY(1,1) PRIMARY KEY, Name NVARCHAR(30), Latin VARCHAR(30));
INSERT INTO @FemaleName (Name, Latin) VALUES
    (N'Олеся','olesia'), (N'Наталія','nataliia'), (N'Ірина','iryna'), (N'Оксана','oksana'),
    (N'Марія','mariia'), (N'Тетяна','tetiana'), (N'Юлія','yuliia'), (N'Анна','anna'),
    (N'Катерина','kateryna'), (N'Світлана','svitlana'), (N'Галина','halyna'), (N'Ольга','olha'),
    (N'Аліна','alina'), (N'Христина','khrystyna'), (N'Софія','sofiia'), (N'Вікторія','viktoriia'),
    (N'Дарина','daryna'), (N'Соломія','solomiia'), (N'Анастасія','anastasiia'), (N'Мирослава','myroslava'),
    (N'Леся','lesia'), (N'Роксолана','roksolana'), (N'Зоряна','zoriana'), (N'Ганна','hanna'),
    (N'Валентина','valentyna'), (N'Лариса','larysa'), (N'Надія','nadiia'), (N'Віра','vira'),
    (N'Любов','liubov'), (N'Уляна','uliana');

/* ---------- По батькові: чоловіча та жіноча форми ---------- */
DECLARE @Patronymic TABLE (ID INT IDENTITY(1,1) PRIMARY KEY, Male NVARCHAR(30), Female NVARCHAR(30));
INSERT INTO @Patronymic (Male, Female) VALUES
    (N'Олександрович',N'Олександрівна'), (N'Андрійович',N'Андріївна'), (N'Іванович',N'Іванівна'),
    (N'Михайлович',N'Михайлівна'), (N'Дмитрович',N'Дмитрівна'), (N'Сергійович',N'Сергіївна'),
    (N'Володимирович',N'Володимирівна'), (N'Петрович',N'Петрівна'), (N'Юрійович',N'Юріївна'),
    (N'Богданович',N'Богданівна'), (N'Васильович',N'Василівна'), (N'Вікторович',N'Вікторівна'),
    (N'Олегович',N'Олегівна'), (N'Романович',N'Романівна'), (N'Ярославович',N'Ярославівна'),
    (N'Миколайович',N'Миколаївна'), (N'Григорович',N'Григорівна'), (N'Степанович',N'Степанівна'),
    (N'Ігорович',N'Ігорівна'), (N'Євгенович',N'Євгенівна');

/* ---------- Прізвища (однакові для чоловіків і жінок) ---------- */
DECLARE @Surname TABLE (ID INT IDENTITY(1,1) PRIMARY KEY, Name NVARCHAR(30), Latin VARCHAR(30));
INSERT INTO @Surname (Name, Latin) VALUES
    (N'Шевченко','shevchenko'), (N'Мартинишин','martynyshyn'), (N'Коваленко','kovalenko'), (N'Бойко','boiko'),
    (N'Лесяк','lesiak'), (N'Кравченко','kravchenko'), (N'Проців','protsiv'), (N'Шевчук','shevchuk'),
    (N'Поліщук','polishchuk'), (N'Мельник','melnyk'), (N'Лисенко','lysenko'), (N'Савченко','savchenko'),
    (N'Балюк','baliuk'), (N'Гавай','havai'), (N'Мороз','moroz'), (N'Петренко','petrenko'),
    (N'Кузьменко','kuzmenko'), (N'Павленко','pavlenko'), (N'Левченко','levchenko'), (N'Ковальчук','kovalchuk'),
    (N'Гончаренко','honcharenko'), (N'Харченко','kharchenko'), (N'Сидоренко','sydorenko'), (N'Мартинюк','martyniuk'),
    (N'Романюк','romaniuk'), (N'Ткачук','tkachuk'), (N'Литвиненко','lytvynenko'), (N'Карпенко','karpenko'),
    (N'Путьо','puto'), (N'Ющенко','yushchenko'), (N'Ничипорук','nychyporuk'), (N'Остапчук','ostapchuk'),
    (N'Захарчук','zakharchuk'), (N'Семенюк','semeniuk'), (N'Дмитренко','dmytrenko'), (N'Яковенко','yakovenko'),
    (N'Гуменюк','humeniuk'), (N'Федорук','fedoruk'), (N'Демченко','demchenko'), (N'Мазур','mazur'),
    (N'Онищенко','onyshchenko'), (N'Зінченко','zinchenko'), (N'Приходько','prykhodko'), (N'Костенко','kostenko'),
    (N'Василенко','vasylenko'), (N'Фесенко','fesenko'), (N'Клименко','klymenko'), (N'Сорока','soroka'),
    (N'Головко','holovko'), (N'Білик','bilyk'), (N'Юрченко','yurchenko'), (N'Довженко','dovzhenko'),
    (N'Іваненко','ivanenko'), (N'Панченко','panchenko'), (N'Стасюк','stasiuk'), (N'Пилипенко','pylypenko'),
    (N'Данилюк','danyliuk'), (N'Гордієнко','hordiienko'), (N'Остапенко','ostapenko'), (N'Порошенко','poroshenko');

/* ---------- Назви компаній: дві частини + організаційна форма ---------- */
DECLARE @CompanyPart1 TABLE (ID INT IDENTITY(1,1) PRIMARY KEY, Name NVARCHAR(20), Latin VARCHAR(20));
INSERT INTO @CompanyPart1 (Name, Latin) VALUES
    (N'Укр','ukr'), (N'Галич','halych'), (N'Дніпро','dnipro'), (N'Карпат','karpat'), (N'Захід','zakhid'),
    (N'Схід','skhid'), (N'Київ','kyiv'), (N'Лев','lev'), (N'Мега','mega'), (N'Нова','nova'),
    (N'Прайм','prime'), (N'Еко','eco'), (N'Альфа','alfa'), (N'Вест','west'), (N'Інтер','inter'),
    (N'Агро','agro'), (N'Техно','tekhno'), (N'Смарт','smart'), (N'Бест','best'), (N'Поділля','podillia');

DECLARE @CompanyPart2 TABLE (ID INT IDENTITY(1,1) PRIMARY KEY, Name NVARCHAR(20), Latin VARCHAR(20));
INSERT INTO @CompanyPart2 (Name, Latin) VALUES
    (N'Буд','bud'), (N'Торг','torh'), (N'Сервіс','servis'), (N'Інвест','invest'), (N'Логістик','lohistyk'),
    (N'Трейд','trade'), (N'Груп','group'), (N'Консалт','consult'), (N'Софт','soft'), (N'Маркет','market'),
    (N'Фарм','farm'), (N'Медіа','media'), (N'Девелопмент','development'), (N'Плюс','plus'), (N'Систем','system'),
    (N'Капітал','capital'), (N'Пром','prom'), (N'Енерго','enerho'), (N'Тех','tech'), (N'Дім','dim');

-- Коди мобільних операторів України
DECLARE @Operator TABLE (ID INT IDENTITY(1,1) PRIMARY KEY, Code CHAR(2));
INSERT INTO @Operator (Code) VALUES
    ('50'), ('63'), ('66'), ('67'), ('68'), ('73'), ('93'), ('95'), ('96'), ('97'), ('98'), ('99');

/* =====================================================================
   1. Випадкові параметри для кожного орендаря
   ===================================================================== */
WITH N AS (
    SELECT TOP (@TenantCount) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
)
SELECT
    n,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100       AS rType,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100       AS rGender,
    ABS(CHECKSUM(NEWID()) % 1000000) % 30 + 1    AS FirstNameID,
    ABS(CHECKSUM(NEWID()) % 1000000) % 20 + 1    AS PatronymicID,
    ABS(CHECKSUM(NEWID()) % 1000000) % 60 + 1    AS SurnameID,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100       AS rForm,
    ABS(CHECKSUM(NEWID()) % 1000000) % 20 + 1    AS Part1ID,
    ABS(CHECKSUM(NEWID()) % 1000000) % 20 + 1    AS Part2ID,
    ABS(CHECKSUM(NEWID()) % 1000000) % 12 + 1    AS OperatorID,
    ABS(CHECKSUM(NEWID()) % 10000000)            AS PhoneNumber,   -- 7 цифр
    ABS(CHECKSUM(NEWID()) % 1000000) % 10        AS rDomain,
    ABS(CHECKSUM(NEWID()) % 1000000) % 100       AS rEmail
INTO #Rnd
FROM N;

/* =====================================================================
   2. Орендарі
      Фізособа:  «Прізвище Ім'я По батькові», РНОКПП 10 цифр, у 20 % немає email
      ФОП:       «Прізвище Ім'я По батькові» (тип видно з TenantTypeID), РНОКПП 10 цифр
      Юрособа:   «ТОВ «ГаличТорг»», ЄДРПОУ 8 цифр
      Податковий код: (n × 7919 + зсув) mod M — взаємно однозначне для n < M,
      тому коди унікальні без додаткових перевірок.
   ===================================================================== */
WITH T AS (
    SELECT
        r.*,
        CASE WHEN r.rType < @PctPerson          THEN 1
             WHEN r.rType < @PctPerson + @PctFop THEN 2
             ELSE 3 END                                          AS TenantTypeID,
        CASE WHEN r.rGender < 50 THEN mn.Name  ELSE fn.Name  END AS FirstName,
        CASE WHEN r.rGender < 50 THEN mn.Latin ELSE fn.Latin END AS FirstLatin,
        CASE WHEN r.rGender < 50 THEN pa.Male  ELSE pa.Female END AS Patronymic,
        sn.Name   AS Surname,
        sn.Latin  AS SurnameLatin,
        CASE WHEN r.rForm < 70 THEN N'ТОВ' WHEN r.rForm < 90 THEN N'ПП' ELSE N'ПрАТ' END AS CompanyForm,
        CONCAT(p1.Name, p2.Name)   AS CompanyName,
        CONCAT(p1.Latin, p2.Latin) AS CompanyLatin,
        op.Code   AS OperatorCode,
        CASE WHEN r.rDomain < 5 THEN 'gmail.com'
             WHEN r.rDomain < 8 THEN 'ukr.net'
             WHEN r.rDomain < 9 THEN 'i.ua'
             ELSE 'meta.ua' END   AS EmailDomain
    FROM #Rnd AS r
    JOIN @MaleName     AS mn ON mn.ID = r.FirstNameID
    JOIN @FemaleName   AS fn ON fn.ID = r.FirstNameID
    JOIN @Patronymic   AS pa ON pa.ID = r.PatronymicID
    JOIN @Surname      AS sn ON sn.ID = r.SurnameID
    JOIN @CompanyPart1 AS p1 ON p1.ID = r.Part1ID
    JOIN @CompanyPart2 AS p2 ON p2.ID = r.Part2ID
    JOIN @Operator     AS op ON op.ID = r.OperatorID
)
INSERT INTO dbo.Tenant (TenantTypeID, Name, TaxCode, Phone, Email)
SELECT
    TenantTypeID,
    CASE TenantTypeID
        WHEN 3 THEN CONCAT(CompanyForm, N' «', CompanyName, N'»')
        ELSE        CONCAT(Surname, N' ', FirstName, N' ', Patronymic)
    END,
    CASE WHEN TenantTypeID = 3
         THEN CAST(10000000   + (n * CAST(7919 AS BIGINT) + 12345)  % 90000000   AS VARCHAR(10))
         ELSE CAST(1000000000 + (n * CAST(7919 AS BIGINT) + 123457) % 9000000000 AS VARCHAR(10))
    END,
    CONCAT('+380', OperatorCode, RIGHT(CONCAT('0000000', PhoneNumber), 7)),
    CASE
        WHEN TenantTypeID = 3 THEN CONCAT('info', n, '@', CompanyLatin, '.com.ua')
        WHEN TenantTypeID = 1 AND rEmail < 20 THEN NULL
        ELSE CONCAT(FirstLatin, '.', SurnameLatin, n % 100, '@', EmailDomain)
    END
FROM T
ORDER BY n;

SET @Rows = @@ROWCOUNT;
RAISERROR(N'Tenant: %d', 0, 1, @Rows) WITH NOWAIT;

DROP TABLE #Rnd;
GO
