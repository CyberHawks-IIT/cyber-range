IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'CYBERHAWKS\svc-mssql')
BEGIN
    CREATE LOGIN [CYBERHAWKS\svc-mssql] FROM WINDOWS;
END
IF NOT IS_SRVROLEMEMBER('sysadmin', 'CYBERHAWKS\svc-mssql') = 1
BEGIN
    ALTER SERVER ROLE sysadmin ADD MEMBER [CYBERHAWKS\svc-mssql];
END

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'CYBERHAWKS\Domain Users')
BEGIN
    CREATE LOGIN [CYBERHAWKS\Domain Users] FROM WINDOWS;
END

ALTER LOGIN sa ENABLE;
ALTER LOGIN sa WITH PASSWORD = '$(SaPassword)';

GRANT IMPERSONATE ON LOGIN::sa TO [CYBERHAWKS\Domain Users];

-- @useself='True' would delegate the CALLING login's own identity to SQL2
-- (a real double-hop needing Kerberos delegation on sql1$, which isn't
-- configured here). The actual "any local login reaches sysadmin via the
-- link" finding instead maps ALL local logins to static sa credentials on
-- SQL2 -- no delegation needed, matches the well-known real-world technique.
IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = 'SQL2')
BEGIN
    EXEC sp_addlinkedserver @server = N'SQL2', @srvproduct = N'SQL Server';
END
EXEC sp_addlinkedsrvlogin @rmtsrvname = N'SQL2', @useself = N'False', @locallogin = NULL, @rmtuser = N'sa', @rmtpassword = N'$(SaPassword)';

PRINT 'sql1 misconfiguration applied';
