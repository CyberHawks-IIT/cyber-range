IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'CYBERHAWKS\svc-mssql')
BEGIN
    CREATE LOGIN [CYBERHAWKS\svc-mssql] FROM WINDOWS;
END
IF NOT IS_SRVROLEMEMBER('sysadmin', 'CYBERHAWKS\svc-mssql') = 1
BEGIN
    ALTER SERVER ROLE sysadmin ADD MEMBER [CYBERHAWKS\svc-mssql];
END

-- sql1's linked server maps to this sa login/password (see
-- mssql_config_sql1.sql) so any local login on sql1 reaches sysadmin here.
ALTER LOGIN sa ENABLE;
ALTER LOGIN sa WITH PASSWORD = '$(SaPassword)';

PRINT 'sql2 misconfiguration applied';
