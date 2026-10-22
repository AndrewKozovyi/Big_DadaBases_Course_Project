USE [master];
GO

-- Повна резервна копія бази зі згенерованими даними.
-- Файл зберігається в стандартну папку резервних копій екземпляра SQL Server
-- (шлях виводиться у вкладці Messages), ім'я містить дату й час створення.
DECLARE @BackupDir  NVARCHAR(4000) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(4000));
DECLARE @BackupFile NVARCHAR(4000) =
    @BackupDir + N'\Rental_generated_' + FORMAT(SYSDATETIME(), 'yyyyMMdd_HHmm') + N'.bak';

BACKUP DATABASE [Rental]
    TO DISK = @BackupFile
    WITH INIT,
         COMPRESSION,
         NAME = N'Rental — згенеровані дані',
         STATS = 10;

-- Перевірка, що копію можна відновити
RESTORE VERIFYONLY FROM DISK = @BackupFile;

PRINT N'Резервну копію збережено: ' + @BackupFile;
GO
