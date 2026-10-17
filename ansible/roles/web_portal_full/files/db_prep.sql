-- web_portal_full DB prep (runs on sql1, before the app first starts).
--
-- The full MVC portal creates and seeds its OWN database via EF Core
-- (DbSeeder -> EnsureCreated) on first start, with a schema different from the
-- Web Forms placeholder's. So we:
--   1. drop any stale CyberHawksPortal DB a prior placeholder run left behind
--      (EnsureCreated only builds the schema when the DB does NOT already
--      exist, so a leftover DB would leave the app with no tables);
--   2. (re)create the svc-web SQL login with the password the site's leaked
--      Web.config.bak advertises;
--   3. grant svc-web dbcreator, so its own EnsureCreated can create the DB
--      (it becomes dbo of what it creates).
-- The "readable by all domain users" finding is applied afterwards, once the
-- app has created the DB (see grant_domain_users.sql).

IF DB_ID('$(PortalDb)') IS NOT NULL
BEGIN
    ALTER DATABASE [$(PortalDb)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$(PortalDb)];
    PRINT 'Dropped stale $(PortalDb) database';
END
GO

-- Clean up the old placeholder "websvc" name if an earlier run created it.
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'websvc')
    DROP LOGIN websvc;
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

-- The app owns its own database, so its login needs to be able to create it.
ALTER SERVER ROLE dbcreator ADD MEMBER [svc-web];
GO

PRINT 'svc-web login ready; $(PortalDb) will be created by the app on first start';
