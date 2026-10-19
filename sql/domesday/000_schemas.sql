/*
  aubreys-automation / sql / domesday
  Run files in numeric order. Every script is safe to re-run where noted;
  table scripts create objects only if they do not already exist.

  Schemas:
    ops   IT-wide automation logging, feed expectations, alert routing (all domains)
    stg   load-and-throw-away staging tables written by ADF Copy activities
    ig    InfoGenesis data (existing schema; the legacy ig.mi_* tables are untouched)
    menu  website menu model: sections, product class map, attribute (SKU) types, publishing
*/
IF SCHEMA_ID(N'ops')  IS NULL EXEC (N'CREATE SCHEMA ops AUTHORIZATION dbo');
IF SCHEMA_ID(N'stg')  IS NULL EXEC (N'CREATE SCHEMA stg AUTHORIZATION dbo');
IF SCHEMA_ID(N'ig')   IS NULL EXEC (N'CREATE SCHEMA ig AUTHORIZATION dbo');
IF SCHEMA_ID(N'menu') IS NULL EXEC (N'CREATE SCHEMA menu AUTHORIZATION dbo');
GO
