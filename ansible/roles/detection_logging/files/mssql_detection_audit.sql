-- SQL Server telemetry needed by splunk-detections/detections/backlog.md's
-- four MSSQL detections (see cyber-range's CLAUDE.md, "Monitoring rollout
-- plan"): xp_cmdshell execution, xp_dirtree execution, EXECUTE AS
-- impersonation, and linked-server command execution. Confirmed live before
-- this script existed: neither sql1 nor sql2 had any SQL Server Audit
-- configured (sys.server_audits returned 0 rows on both).

-- --- Dedicated monitoring login for defense-tooling's Splunk DB Connect ---
-- Deliberately NOT svc-mssql or any other in-range attack-target account --
-- a distinct identity so this monitoring path isn't itself one of the
-- range's findings.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'svc-sqlmonitor')
BEGIN
    CREATE LOGIN [svc-sqlmonitor] WITH PASSWORD = N'$(MonitorPassword)', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
END
ELSE
BEGIN
    ALTER LOGIN [svc-sqlmonitor] WITH PASSWORD = N'$(MonitorPassword)';
END

-- sys.fn_xe_file_target_read_file() and sys.fn_get_audit_file() (both used
-- below to read this data back) each require CONTROL SERVER permission (or
-- sysadmin) per Microsoft's documented requirements for these functions --
-- there is no narrower built-in server-level permission that unlocks them.
GRANT CONTROL SERVER TO [svc-sqlmonitor];

-- --- Extended Events: full statement text for xp_cmdshell, xp_dirtree,
-- linked-server-driven execution (OPENQUERY/EXECUTE AT/four-part names all
-- surface here as an RPC or SQL-batch completion with the sql_text action
-- attached), and the portal Users-table read -- one session covers those
-- four named detections. ---
--
-- SCOPED BY PREDICATE (2026-09-29): the session originally captured EVERY
-- sql_batch_completed / rpc_completed (the sql_text action on all of them),
-- which produced ~37 events/sec (2.8M rows in ~21h). fn_xe_file_target_read_file
-- over the resulting 500 MB of rollover files could not complete within the
-- Splunk DB Connect connection timeout, so the xe_text input failed every poll
-- ("Connection is closed") and the checkpoint never advanced -- mssql_xe_text
-- ingestion silently stopped and the four detections went blind. The four
-- xe_text detections only ever match four narrow statement substrings, so the
-- session now captures only statements containing those substrings via a
-- like_i_sql_unicode_string predicate on the sql_text action. This cuts the
-- capture volume by orders of magnitude, keeps fn_xe_file_target_read_file
-- fast, and does not change what the detections can match (they filter the
-- same substrings). Adding a new statement-text SQL detection means adding its
-- substring here too. (Content matching in the CAPTURE layer only -- the
-- action-based rule governs Windows process/command-line detections, not the
-- SQL statement text that is itself the only telemetry for these techniques.)
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'detection_sql_text')
BEGIN
    ALTER EVENT SESSION [detection_sql_text] ON SERVER STATE = STOP;
END
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'detection_sql_text')
BEGIN
    DROP EVENT SESSION [detection_sql_text] ON SERVER;
END

CREATE EVENT SESSION [detection_sql_text] ON SERVER
ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.sql_text, sqlserver.username, sqlserver.client_hostname)
    WHERE (
        [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%xp_cmdshell%')
        OR [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%xp_dirtree%')
        OR [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%OPENQUERY%')
        OR [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%FROM Users%')
    )
),
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.sql_text, sqlserver.username, sqlserver.client_hostname)
    WHERE (
        [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%xp_cmdshell%')
        OR [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%xp_dirtree%')
        OR [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%OPENQUERY%')
        OR [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%FROM Users%')
    )
)
ADD TARGET package0.event_file (
    SET filename = N'detection_sql_text.xel', max_file_size = 50, max_rollover_files = 10
)
WITH (
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE = ON
);

ALTER EVENT SESSION [detection_sql_text] ON SERVER STATE = START;

-- --- Server Audit Specification: EXECUTE AS impersonation as structured
-- who-became-whom fields, rather than parsed out of XE statement text. ---
IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = 'detection_impersonation_audit_spec')
BEGIN
    ALTER SERVER AUDIT SPECIFICATION [detection_impersonation_audit_spec] WITH (STATE = OFF);
    DROP SERVER AUDIT SPECIFICATION [detection_impersonation_audit_spec];
END
IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = 'detection_impersonation_audit')
BEGIN
    ALTER SERVER AUDIT [detection_impersonation_audit] WITH (STATE = OFF);
    DROP SERVER AUDIT [detection_impersonation_audit];
END

-- Hardcoded rather than passed as a sqlcmd -v variable: sqlcmd's own
-- argument parser mangles a value containing both a drive-letter colon and
-- backslashes (confirmed live -- "Sqlcmd: ':\SQLAudit': Invalid argument"),
-- and this path isn't a secret like the password variables above, so
-- there's no reason to thread it through the shell layer at all. Must match
-- create_sql_audit_dir.ps1's $auditDir.
CREATE SERVER AUDIT [detection_impersonation_audit]
TO FILE (FILEPATH = N'C:\SQLAudit', MAXSIZE = 50 MB, MAX_ROLLOVER_FILES = 10)
WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);

ALTER SERVER AUDIT [detection_impersonation_audit] WITH (STATE = ON);

CREATE SERVER AUDIT SPECIFICATION [detection_impersonation_audit_spec]
FOR SERVER AUDIT [detection_impersonation_audit]
ADD (SERVER_PRINCIPAL_IMPERSONATION_GROUP),
ADD (DATABASE_PRINCIPAL_IMPERSONATION_GROUP)
WITH (STATE = ON);

PRINT 'sql detection logging applied';
