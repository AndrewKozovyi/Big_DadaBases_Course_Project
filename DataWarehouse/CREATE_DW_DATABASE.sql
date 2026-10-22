USE [master];
GO

-- Сховище створюється лише якщо його ще немає (повторний запуск безпечний)
IF DB_ID(N'RentalDW') IS NULL
BEGIN
    CREATE DATABASE [RentalDW]
        COLLATE Ukrainian_100_CI_AS;
END;
GO

-- SIMPLE recovery: сховище перезавантажується з OLTP, журнал не потрібен для відновлення
ALTER DATABASE [RentalDW] SET RECOVERY SIMPLE;
GO

PRINT N'Сховище RentalDW готове.';
GO
