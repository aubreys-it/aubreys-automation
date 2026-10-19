/*
  ops: IT-wide automation log. The menu pipeline is the first domain to use it.

  area              who hears about problems (Slack channel + email group). One per department area.
  domain            a process (menus, payroll, ap ...). Belongs to one area.
  event_code        catalog of event codes with severity and "how to fix" text used in emails.
  feed_expectation  what SHOULD arrive and how fresh it must be (this is how missing files get noticed).
  feed_arrival      what DID arrive.
  pipeline_run      one row per pipeline run.
  run_event         append-only event log.
  notification      every Slack/email notification sent (audit + dedupe).
*/

IF OBJECT_ID(N'ops.area') IS NULL
CREATE TABLE ops.area (
    areaCode         varchar(20)   NOT NULL CONSTRAINT PK_ops_area PRIMARY KEY,
    description      nvarchar(200) NULL,
    slackChannel     varchar(80)   NULL,     -- for humans; the webhook URL lives in Key Vault
    slackSecretName  varchar(127)  NULL,     -- Key Vault secret holding the Slack incoming-webhook URL
    emailTo          nvarchar(320) NULL,     -- mail-enabled security group
    emailReplyTo     nvarchar(320) NULL,
    isActive         bit           NOT NULL CONSTRAINT DF_ops_area_isActive DEFAULT (1)
);
GO

IF OBJECT_ID(N'ops.domain') IS NULL
CREATE TABLE ops.domain (
    domainCode   varchar(40)   NOT NULL CONSTRAINT PK_ops_domain PRIMARY KEY,
    areaCode     varchar(20)   NOT NULL CONSTRAINT FK_ops_domain_area REFERENCES ops.area (areaCode),
    displayName  nvarchar(60)  NOT NULL,
    description  nvarchar(400) NULL,
    docPath      nvarchar(200) NULL,         -- e.g. docs/domains/menus.md
    isActive     bit           NOT NULL CONSTRAINT DF_ops_domain_isActive DEFAULT (1)
);
GO

IF OBJECT_ID(N'ops.event_code') IS NULL
CREATE TABLE ops.event_code (
    code             varchar(40)    NOT NULL CONSTRAINT PK_ops_event_code PRIMARY KEY,
    defaultSeverity  varchar(5)     NOT NULL CONSTRAINT CK_ops_event_code_sev CHECK (defaultSeverity IN ('INFO','WARN','ERROR')),
    title            nvarchar(100)  NOT NULL,
    howToFix         nvarchar(1000) NULL
);
GO

IF OBJECT_ID(N'ops.feed_expectation') IS NULL
CREATE TABLE ops.feed_expectation (
    domainCode   varchar(40)   NOT NULL CONSTRAINT FK_ops_feedexp_domain REFERENCES ops.domain (domainCode),
    feedCode     varchar(40)   NOT NULL,
    locId        int           NOT NULL CONSTRAINT DF_ops_feedexp_locId DEFAULT (0),  -- 0 = not store-specific
    maxAgeHours  int           NOT NULL,
    isActive     bit           NOT NULL CONSTRAINT DF_ops_feedexp_isActive DEFAULT (1),
    note         nvarchar(200) NULL,
    CONSTRAINT PK_ops_feed_expectation PRIMARY KEY (domainCode, feedCode, locId)
);
GO

IF OBJECT_ID(N'ops.feed_arrival') IS NULL
BEGIN
    CREATE TABLE ops.feed_arrival (
        arrivalId          bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ops_feed_arrival PRIMARY KEY,
        domainCode         varchar(40)  NOT NULL,
        feedCode           varchar(40)  NOT NULL,
        locId              int          NOT NULL,
        runId              varchar(64)  NULL,
        sourceModifiedUtc  datetime2(0) NULL,     -- file timestamp at the source (IG SFTP)
        arrivedUtc         datetime2(0) NOT NULL CONSTRAINT DF_ops_feed_arrival_at DEFAULT (SYSUTCDATETIME()),
        [rowCount]         int          NULL,
        sourcePath         nvarchar(400) NULL
    );
    CREATE INDEX IX_ops_feed_arrival_feed ON ops.feed_arrival (domainCode, feedCode, locId, arrivedUtc DESC)
        INCLUDE (sourceModifiedUtc, runId);
    CREATE INDEX IX_ops_feed_arrival_run ON ops.feed_arrival (runId);
END
GO

IF OBJECT_ID(N'ops.pipeline_run') IS NULL
BEGIN
    CREATE TABLE ops.pipeline_run (
        runId         varchar(64)   NOT NULL CONSTRAINT PK_ops_pipeline_run PRIMARY KEY,  -- ADF pipeline().RunId
        domainCode    varchar(40)   NOT NULL,
        pipelineName  nvarchar(140) NOT NULL,
        triggerName   nvarchar(140) NULL,
        triggerType   varchar(40)   NULL,
        startedUtc    datetime2(0)  NOT NULL CONSTRAINT DF_ops_pipeline_run_start DEFAULT (SYSUTCDATETIME()),
        endedUtc      datetime2(0)  NULL,
        status        varchar(12)   NOT NULL CONSTRAINT DF_ops_pipeline_run_status DEFAULT ('Running')
                      CONSTRAINT CK_ops_pipeline_run_status CHECK (status IN ('Running','Succeeded','Warning','Failed')),
        summary       nvarchar(max) NULL CONSTRAINT CK_ops_pipeline_run_summary CHECK (summary IS NULL OR ISJSON(summary) = 1)
    );
    CREATE INDEX IX_ops_pipeline_run_domain ON ops.pipeline_run (domainCode, startedUtc DESC) INCLUDE (status, endedUtc);
END
GO

IF OBJECT_ID(N'ops.run_event') IS NULL
BEGIN
    CREATE TABLE ops.run_event (
        eventId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ops_run_event PRIMARY KEY,
        runId       varchar(64)    NULL,
        domainCode  varchar(40)    NOT NULL,
        loggedUtc   datetime2(3)   NOT NULL CONSTRAINT DF_ops_run_event_at DEFAULT (SYSUTCDATETIME()),
        severity    varchar(5)     NOT NULL CONSTRAINT CK_ops_run_event_sev CHECK (severity IN ('INFO','WARN','ERROR')),
        step        nvarchar(100)  NULL,
        locId       int            NULL,
        itemId      int            NULL,
        code        varchar(40)    NOT NULL,
        message     nvarchar(1000) NOT NULL,
        detail      nvarchar(max)  NULL CONSTRAINT CK_ops_run_event_detail CHECK (detail IS NULL OR ISJSON(detail) = 1)
    );
    CREATE INDEX IX_ops_run_event_run ON ops.run_event (runId, severity) INCLUDE (code, locId, itemId);
    CREATE INDEX IX_ops_run_event_domain ON ops.run_event (domainCode, loggedUtc DESC) INCLUDE (severity, code);
END
GO

IF OBJECT_ID(N'ops.notification') IS NULL
CREATE TABLE ops.notification (
    notificationId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ops_notification PRIMARY KEY,
    runId           varchar(64)   NULL,
    domainCode      varchar(40)   NULL,
    areaCode        varchar(20)   NULL,
    channel         varchar(10)   NOT NULL CONSTRAINT CK_ops_notification_channel CHECK (channel IN ('slack','email')),
    kind            varchar(12)   NOT NULL CONSTRAINT CK_ops_notification_kind CHECK (kind IN ('alert','digest','watchdog')),
    sentUtc         datetime2(0)  NOT NULL CONSTRAINT DF_ops_notification_at DEFAULT (SYSUTCDATETIME()),
    recipient       nvarchar(320) NULL,
    subject         nvarchar(300) NULL,
    status          varchar(10)   NOT NULL CONSTRAINT CK_ops_notification_status CHECK (status IN ('sent','failed')),
    detail          nvarchar(max) NULL
);
GO
