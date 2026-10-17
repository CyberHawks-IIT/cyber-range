-- web_portal_full: apply the "portal DB readable by all domain users" finding
-- AFTER the app has created and seeded its database on first start.
--
-- Ties into the "sql1 open to all domain users" MSSQL finding -- the portal's
-- own database is readable by any domain user, not just the app's svc-web
-- login. The CYBERHAWKS\Domain Users LOGIN already exists on sql1 (granted by
-- the mssql_misconfig role); here we just map it into the portal DB and give
-- it read.

USE [$(PortalDb)];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'CYBERHAWKS\Domain Users')
BEGIN
    CREATE USER [CYBERHAWKS\Domain Users] FOR LOGIN [CYBERHAWKS\Domain Users];
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals p ON drm.member_principal_id = p.principal_id
    WHERE p.name = 'CYBERHAWKS\Domain Users'
      AND drm.role_principal_id = DATABASE_PRINCIPAL_ID('db_datareader'))
BEGIN
    ALTER ROLE db_datareader ADD MEMBER [CYBERHAWKS\Domain Users];
END
GO

PRINT '$(PortalDb) is now readable by CYBERHAWKS\Domain Users';
