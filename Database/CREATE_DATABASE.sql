USE [master];
GO

-- База створюється лише якщо її ще немає (повторний запуск безпечний)
IF DB_ID(N'Rental') IS NULL
BEGIN
    CREATE DATABASE [Rental]
        COLLATE Ukrainian_100_CI_AS;   -- коректне сортування та порівняння українських рядків
END;
GO

-- SIMPLE recovery: менший журнал транзакцій під час масової генерації даних (~560 тис. рядків)
ALTER DATABASE [Rental] SET RECOVERY SIMPLE;
GO

-- Тригери не викликають самі себе рекурсивно (значення за замовчуванням, фіксуємо явно)
ALTER DATABASE [Rental] SET RECURSIVE_TRIGGERS OFF;
GO

PRINT N'База даних Rental готова.';
GO
