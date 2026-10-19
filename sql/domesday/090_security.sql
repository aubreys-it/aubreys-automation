/*
  Database access. Run as an Entra admin of mcp-alex (contained users from Entra; no SQL logins).

  automation_writer  ADF (adf-aub-ops managed identity): run procs, write staging.
  ops_reader         read-only view of the ops log: daily briefing, dashboard, future MCP server.
                     Granted to the "Automation Ops Admins" mail-enabled security group so
                     adding someone to the group gives them both the emails and the read access.
*/
IF DATABASE_PRINCIPAL_ID(N'automation_writer') IS NULL CREATE ROLE automation_writer;
IF DATABASE_PRINCIPAL_ID(N'ops_reader')        IS NULL CREATE ROLE ops_reader;
GO

GRANT EXECUTE ON SCHEMA::ops  TO automation_writer;
GRANT EXECUTE ON SCHEMA::ig   TO automation_writer;
GRANT EXECUTE ON SCHEMA::menu TO automation_writer;
GRANT SELECT, INSERT, DELETE ON SCHEMA::stg TO automation_writer;   -- Copy activity bulk insert + pre-copy DELETE
GRANT SELECT ON SCHEMA::menu TO automation_writer;                  -- Lookup: list of stores
GRANT SELECT ON SCHEMA::ops  TO automation_writer;
GO

GRANT SELECT ON SCHEMA::ops TO ops_reader;
GRANT SELECT ON OBJECT::ig.mi_store_load TO ops_reader;
GRANT SELECT ON OBJECT::menu.publish_state TO ops_reader;
GO

/* Managed identity of the data factory. The name is the factory name. */
IF DATABASE_PRINCIPAL_ID(N'adf-aub-ops') IS NULL
    CREATE USER [adf-aub-ops] FROM EXTERNAL PROVIDER;
ALTER ROLE automation_writer ADD MEMBER [adf-aub-ops];
GO

/* Uncomment once the group exists (Exchange admin center -> Groups -> Mail-enabled security). */
-- IF DATABASE_PRINCIPAL_ID(N'Automation Ops Admins') IS NULL
--     CREATE USER [Automation Ops Admins] FROM EXTERNAL PROVIDER;
-- ALTER ROLE ops_reader ADD MEMBER [Automation Ops Admins];
GO
