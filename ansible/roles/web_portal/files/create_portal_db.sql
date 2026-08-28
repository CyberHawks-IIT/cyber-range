-- Clean up the old "websvc" name if a prior run created it (renamed to
-- svc-web to match this range's svc-<name> service-account convention).
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'websvc')
BEGIN
    IF DB_ID('CyberHawksPortal') IS NOT NULL
    BEGIN
        EXEC('USE CyberHawksPortal; IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''websvc'') DROP USER websvc;');
    END
    DROP LOGIN websvc;
END
GO

IF DB_ID('CyberHawksPortal') IS NULL
BEGIN
    CREATE DATABASE CyberHawksPortal;
END
GO

USE CyberHawksPortal;

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Users')
BEGIN
    CREATE TABLE Users (
        Id INT IDENTITY PRIMARY KEY,
        Username NVARCHAR(50) NOT NULL UNIQUE,
        PasswordHash CHAR(40) NOT NULL
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM Users WHERE Username = 'admin')
BEGIN
    INSERT INTO Users (Username, PasswordHash) VALUES ('admin', CONVERT(CHAR(40), HASHBYTES('SHA1', 'abc123'), 2));
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'svc-web')
BEGIN
    CREATE LOGIN [svc-web] WITH PASSWORD = '$(SvcWebPassword)';
END
ELSE
BEGIN
    ALTER LOGIN [svc-web] WITH PASSWORD = '$(SvcWebPassword)';
END
GO

USE CyberHawksPortal;

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'svc-web')
BEGIN
    CREATE USER [svc-web] FOR LOGIN [svc-web];
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm JOIN sys.database_principals p ON drm.member_principal_id = p.principal_id WHERE p.name = 'svc-web' AND drm.role_principal_id = DATABASE_PRINCIPAL_ID('db_datareader'))
BEGIN
    ALTER ROLE db_datareader ADD MEMBER [svc-web];
END
GO

-- Ties into the "sql1 open to all domain users" MSSQL finding -- the
-- portal's own database is readable by any domain user too, not just the
-- app's own service login.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'CYBERHAWKS\Domain Users')
BEGIN
    CREATE USER [CYBERHAWKS\Domain Users] FOR LOGIN [CYBERHAWKS\Domain Users];
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm JOIN sys.database_principals p ON drm.member_principal_id = p.principal_id WHERE p.name = 'CYBERHAWKS\Domain Users' AND drm.role_principal_id = DATABASE_PRINCIPAL_ID('db_datareader'))
BEGIN
    ALTER ROLE db_datareader ADD MEMBER [CYBERHAWKS\Domain Users];
END
GO

PRINT 'CyberHawksPortal database configured';
