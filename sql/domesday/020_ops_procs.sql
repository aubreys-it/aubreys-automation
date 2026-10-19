/*
  ops procedures and views. Safe to re-run (CREATE OR ALTER).

  Called by ADF (any domain):
    ops.usp_run_start          at the start of every pipeline run
    ops.usp_log_event          one event
    ops.usp_log_events_json    a batch of events (e.g. the parser's rejected lines)
    ops.usp_record_arrival     a source file / output arrived
    ops.usp_run_end            at the end (status is derived from the events logged)
    ops.usp_run_notifications  returns ready-to-send Slack + Graph sendMail payloads
    ops.usp_log_notification   records what was sent
    ops.usp_watchdog           daily check for late feeds (separate pipeline)
    ops.usp_purge              retention
*/

CREATE OR ALTER FUNCTION ops.fn_html (@s nvarchar(max))
RETURNS nvarchar(max)
WITH SCHEMABINDING
AS
BEGIN
    RETURN REPLACE(REPLACE(REPLACE(REPLACE(@s, N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), N'"', N'&quot;');
END
GO

CREATE OR ALTER FUNCTION ops.fn_eastern (@utc datetime2(3))
RETURNS datetime2(0)
AS
BEGIN
    RETURN CAST(CAST(@utc AS datetimeoffset) AT TIME ZONE 'Eastern Standard Time' AS datetime2(0));
END
GO

/* Microsoft Graph sendMail request body. Recipients are a single address each (the area's group). */
CREATE OR ALTER FUNCTION ops.fn_graph_mail
    (@subject nvarchar(300), @html nvarchar(max), @to nvarchar(320), @replyTo nvarchar(320))
RETURNS nvarchar(max)
AS
BEGIN
    RETURN (
        SELECT @subject AS [message.subject],
               'HTML'   AS [message.body.contentType],
               @html    AS [message.body.content],
               JSON_QUERY((SELECT @to AS [emailAddress.address] FOR JSON PATH)) AS [message.toRecipients],
               JSON_QUERY((SELECT @replyTo AS [emailAddress.address] FOR JSON PATH)) AS [message.replyTo],
               CAST(1 AS bit) AS [saveToSentItems]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
END
GO

CREATE OR ALTER PROCEDURE ops.usp_run_start
    @runId        varchar(64),
    @domainCode   varchar(40),
    @pipelineName nvarchar(140),
    @triggerName  nvarchar(140) = NULL,
    @triggerType  varchar(40)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM ops.pipeline_run WHERE runId = @runId)
        INSERT ops.pipeline_run (runId, domainCode, pipelineName, triggerName, triggerType)
        VALUES (@runId, @domainCode, @pipelineName, @triggerName, @triggerType);
END
GO

CREATE OR ALTER PROCEDURE ops.usp_log_event
    @runId      varchar(64),
    @domainCode varchar(40),
    @code       varchar(40),
    @message    nvarchar(1000),
    @severity   varchar(5)    = NULL,   -- NULL = event_code.defaultSeverity (or ERROR if unknown)
    @step       nvarchar(100) = NULL,
    @locId      int           = NULL,
    @itemId     int           = NULL,
    @detail     nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @severity = COALESCE(@severity, (SELECT defaultSeverity FROM ops.event_code WHERE code = @code), 'ERROR');
    IF @detail IS NOT NULL AND ISJSON(@detail) = 0
        SET @detail = (SELECT @detail AS [text] FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    INSERT ops.run_event (runId, domainCode, severity, step, locId, itemId, code, message, detail)
    VALUES (@runId, @domainCode, @severity, @step, @locId, @itemId, @code, LEFT(@message, 1000), @detail);
END
GO

/* @events: JSON array of {severity?, code, message, step?, locId?, itemId?, detail?} */
CREATE OR ALTER PROCEDURE ops.usp_log_events_json
    @runId      varchar(64),
    @domainCode varchar(40),
    @events     nvarchar(max),
    @step       nvarchar(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @events IS NULL OR ISJSON(@events) = 0 RETURN;
    INSERT ops.run_event (runId, domainCode, severity, step, locId, itemId, code, message, detail)
    SELECT @runId, @domainCode,
           COALESCE(e.severity, ec.defaultSeverity, 'ERROR'),
           COALESCE(e.step, @step), e.locId, e.itemId, e.code, LEFT(e.message, 1000), e.detail
    FROM OPENJSON(@events) WITH (
            severity varchar(5)     '$.severity',
            code     varchar(40)    '$.code',
            message  nvarchar(1000) '$.message',
            step     nvarchar(100)  '$.step',
            locId    int            '$.locId',
            itemId   int            '$.itemId',
            detail   nvarchar(max)  '$.detail' AS JSON) e
    LEFT JOIN ops.event_code ec ON ec.code = e.code
    WHERE e.code IS NOT NULL;
END
GO

CREATE OR ALTER PROCEDURE ops.usp_record_arrival
    @runId             varchar(64),
    @domainCode        varchar(40),
    @feedCode          varchar(40),
    @locId             int,
    @sourceModifiedUtc datetime2(0)  = NULL,
    @rowCount          int           = NULL,
    @sourcePath        nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT ops.feed_arrival (domainCode, feedCode, locId, runId, sourceModifiedUtc, [rowCount], sourcePath)
    VALUES (@domainCode, @feedCode, @locId, @runId, @sourceModifiedUtc, @rowCount, @sourcePath);
END
GO

/* Status is derived: any ERROR = Failed, any WARN = Warning, else Succeeded.
   @failureMessage: ADF passes the error of the core pipeline (empty when it succeeded);
   when present a RUN_FAILED event is logged and the run is marked Failed. */
CREATE OR ALTER PROCEDURE ops.usp_run_end
    @runId          varchar(64),
    @failureMessage nvarchar(4000) = NULL,
    @summary        nvarchar(max)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(RTRIM(@failureMessage)), N'') IS NOT NULL
        INSERT ops.run_event (runId, domainCode, severity, step, code, message, detail)
        SELECT @runId, r.domainCode, 'ERROR', N'pipeline', 'RUN_FAILED', LEFT(@failureMessage, 1000),
               (SELECT @failureMessage AS error FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        FROM ops.pipeline_run r WHERE r.runId = @runId;

    DECLARE @errors int, @warns int;
    SELECT @errors = SUM(CASE WHEN severity = 'ERROR' THEN 1 ELSE 0 END),
           @warns  = SUM(CASE WHEN severity = 'WARN'  THEN 1 ELSE 0 END)
    FROM ops.run_event WHERE runId = @runId;

    UPDATE ops.pipeline_run
       SET endedUtc = SYSUTCDATETIME(),
           status   = CASE WHEN @errors > 0 THEN 'Failed' WHEN @warns > 0 THEN 'Warning' ELSE 'Succeeded' END,
           summary  = COALESCE(@summary, summary)
     WHERE runId = @runId;

    SELECT runId, status, ISNULL(@errors, 0) AS errorCount, ISNULL(@warns, 0) AS warnCount
    FROM ops.pipeline_run WHERE runId = @runId;
END
GO

CREATE OR ALTER PROCEDURE ops.usp_log_notification
    @runId      varchar(64),
    @domainCode varchar(40),
    @channel    varchar(10),
    @kind       varchar(12),
    @status     varchar(10),
    @recipient  nvarchar(320) = NULL,
    @subject    nvarchar(300) = NULL,
    @detail     nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT ops.notification (runId, domainCode, areaCode, channel, kind, recipient, subject, status, detail)
    SELECT @runId, @domainCode, d.areaCode, @channel, @kind, @recipient, @subject, @status, @detail
    FROM (SELECT @domainCode AS dc) x
    LEFT JOIN ops.domain d ON d.domainCode = x.dc;
END
GO

/* ---------- Views for briefings, dashboards, MCP ---------- */

CREATE OR ALTER VIEW ops.v_feed_health
AS
SELECT fe.domainCode, d.areaCode, fe.feedCode, fe.locId, fe.maxAgeHours, fe.note,
       la.lastArrivedUtc, la.lastSourceModifiedUtc, la.lastRunId,
       DATEDIFF(MINUTE, la.lastArrivedUtc, SYSUTCDATETIME()) / 60.0 AS ageHours,
       CAST(CASE WHEN la.lastArrivedUtc IS NULL
                   OR la.lastArrivedUtc < DATEADD(HOUR, -fe.maxAgeHours, SYSUTCDATETIME())
                 THEN 1 ELSE 0 END AS bit) AS isLate
FROM ops.feed_expectation fe
JOIN ops.domain d ON d.domainCode = fe.domainCode
OUTER APPLY (
    SELECT TOP (1) fa.arrivedUtc AS lastArrivedUtc, fa.sourceModifiedUtc AS lastSourceModifiedUtc, fa.runId AS lastRunId
    FROM ops.feed_arrival fa
    WHERE fa.domainCode = fe.domainCode AND fa.feedCode = fe.feedCode AND fa.locId = fe.locId
    ORDER BY fa.arrivedUtc DESC) la
WHERE fe.isActive = 1 AND d.isActive = 1;
GO

/* Latest run per pipeline plus anything from the last 24 hours that was not clean. */
CREATE OR ALTER VIEW ops.v_open_issues
AS
SELECT e.eventId, e.loggedUtc, ops.fn_eastern(e.loggedUtc) AS loggedEastern,
       e.domainCode, d.areaCode, e.severity, e.code, ec.title, e.locId, e.itemId, e.step, e.message,
       ec.howToFix, e.detail, e.runId, r.pipelineName, r.status AS runStatus
FROM ops.run_event e
JOIN ops.domain d ON d.domainCode = e.domainCode
LEFT JOIN ops.event_code ec ON ec.code = e.code
LEFT JOIN ops.pipeline_run r ON r.runId = e.runId
WHERE e.severity IN ('WARN', 'ERROR')
  AND e.loggedUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME());
GO

CREATE OR ALTER VIEW ops.v_daily_summary
AS
SELECT CAST(ops.fn_eastern(r.startedUtc) AS date) AS runDateEastern,
       r.domainCode, d.areaCode, r.pipelineName,
       COUNT(*) AS runs,
       SUM(CASE WHEN r.status = 'Succeeded' THEN 1 ELSE 0 END) AS succeeded,
       SUM(CASE WHEN r.status = 'Warning'   THEN 1 ELSE 0 END) AS warnings,
       SUM(CASE WHEN r.status = 'Failed'    THEN 1 ELSE 0 END) AS failed,
       SUM(CASE WHEN r.status = 'Running'   THEN 1 ELSE 0 END) AS stillRunning,
       MAX(r.endedUtc) AS lastEndedUtc
FROM ops.pipeline_run r
JOIN ops.domain d ON d.domainCode = r.domainCode
GROUP BY CAST(ops.fn_eastern(r.startedUtc) AS date), r.domainCode, d.areaCode, r.pipelineName;
GO

/* ---------- Notification payloads ----------
   Returns one row. ADF checks sendAlert / sendDigest and posts the *Body columns as-is:
     slack*Body  -> POST to the webhook URL read from Key Vault secret slackSecretName
     graph*Body  -> POST https://graph.microsoft.com/v1.0/users/{sender}/sendMail
   Policy (agreed 2026-10-16):
     ERROR events -> specific Slack line + immediate email
     WARN  events -> generic Slack line + one digest email per run
*/
CREATE OR ALTER PROCEDURE ops.usp_run_notifications
    @runId varchar(64)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @domainCode varchar(40), @domainName nvarchar(60), @areaCode varchar(20),
            @slackSecret varchar(127), @emailTo nvarchar(320), @replyTo nvarchar(320),
            @pipeline nvarchar(140), @started datetime2(0), @runDate nvarchar(40);

    SELECT @domainCode = r.domainCode, @domainName = d.displayName, @areaCode = a.areaCode,
           @slackSecret = a.slackSecretName, @emailTo = a.emailTo, @replyTo = COALESCE(a.emailReplyTo, a.emailTo),
           @pipeline = r.pipelineName, @started = r.startedUtc
    FROM ops.pipeline_run r
    JOIN ops.domain d ON d.domainCode = r.domainCode
    JOIN ops.area a ON a.areaCode = d.areaCode
    WHERE r.runId = @runId;

    SET @runDate = FORMAT(ops.fn_eastern(@started), 'ddd MMM d, h:mm tt', 'en-US') + N' ET';

    DECLARE @errCount int = (SELECT COUNT(*) FROM ops.run_event WHERE runId = @runId AND severity = 'ERROR');
    DECLARE @warnCount int = (SELECT COUNT(*) FROM ops.run_event WHERE runId = @runId AND severity = 'WARN');

    DECLARE @errStores nvarchar(200) = (
        SELECT STRING_AGG(s, N', ') WITHIN GROUP (ORDER BY s)
        FROM (SELECT DISTINCT RIGHT('0' + CAST(locId AS varchar(3)), 2) AS s
              FROM ops.run_event WHERE runId = @runId AND severity = 'ERROR' AND locId IS NOT NULL) x);

    DECLARE @warnBreakdown nvarchar(400) = (
        SELECT STRING_AGG(CAST(CONCAT(n, N' ', LOWER(t)) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY n DESC)
        FROM (SELECT COALESCE(ec.title, e.code) AS t, COUNT(*) AS n
              FROM ops.run_event e LEFT JOIN ops.event_code ec ON ec.code = e.code
              WHERE e.runId = @runId AND e.severity = 'WARN'
              GROUP BY COALESCE(ec.title, e.code)) x);

    /* ---- alert (errors) ---- */
    DECLARE @alertSubject nvarchar(300) =
        CONCAT(N'[ALERT][', @areaCode, N'] ', @domainName, N' – ', @errCount,
               CASE WHEN @errCount = 1 THEN N' error' ELSE N' errors' END,
               CASE WHEN @errStores IS NOT NULL THEN N' (' + @errStores + N')' ELSE N'' END);

    DECLARE @alertRows nvarchar(max) = (
        SELECT STRING_AGG(CAST(CONCAT(
                 N'<tr><td>', ISNULL(RIGHT('0' + CAST(e.locId AS varchar(3)), 2), N'–'),
                 N'</td><td>', ops.fn_html(COALESCE(ec.title, e.code)),
                 N'</td><td>', ops.fn_html(e.message),
                 N'</td><td>', ops.fn_html(ISNULL(ec.howToFix, N'')), N'</td></tr>') AS nvarchar(max)), N'')
               WITHIN GROUP (ORDER BY e.locId, e.eventId)
        FROM ops.run_event e LEFT JOIN ops.event_code ec ON ec.code = e.code
        WHERE e.runId = @runId AND e.severity = 'ERROR');

    DECLARE @style nvarchar(400) = N'<style>body{font-family:Segoe UI,Arial,sans-serif;font-size:14px}'
        + N'table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}'
        + N'th{background:#f2f2f2}</style>';

    DECLARE @footer nvarchar(1000) = CONCAT(N'<p style="color:#777;font-size:12px">Pipeline ', ops.fn_html(@pipeline),
        N' · run ', @runId, N' · ', @runDate, N'<br>Query details: SELECT * FROM ops.v_open_issues WHERE runId = ''',
        @runId, N'''</p>');

    DECLARE @alertHtml nvarchar(max) = CONCAT(@style,
        N'<p><b>', ops.fn_html(@domainName), N'</b> had ', @errCount, N' error(s) on the run started ', @runDate, N'.</p>',
        N'<table><tr><th>Store</th><th>Problem</th><th>Detail</th><th>What to do</th></tr>', @alertRows, N'</table>',
        @footer);

    DECLARE @alertSlackText nvarchar(1000) = CONCAT(N':rotating_light: *', @domainName, N'* – ', @errCount,
        CASE WHEN @errCount = 1 THEN N' error' ELSE N' errors' END,
        CASE WHEN @errStores IS NOT NULL THEN N' (stores ' + @errStores + N')' ELSE N'' END,
        N': ', (SELECT TOP (1) LEFT(message, 200) FROM ops.run_event WHERE runId = @runId AND severity = 'ERROR' ORDER BY eventId),
        CASE WHEN @errCount > 1 THEN N' …' ELSE N'' END,
        N' Details emailed to ', @emailTo, N'.');

    /* ---- digest (warnings / exceptions) ---- */
    DECLARE @digestSubject nvarchar(300) =
        CONCAT(N'[EXCEPTIONS][', @areaCode, N'] ', @domainName, N' – ', @warnCount,
               CASE WHEN @warnCount = 1 THEN N' item' ELSE N' items' END);

    DECLARE @digestSections nvarchar(max) = (
        SELECT STRING_AGG(CAST(sect AS nvarchar(max)), N'') WITHIN GROUP (ORDER BY ord)
        FROM (
            SELECT MIN(e.eventId) AS ord,
                   CONCAT(N'<h3>', ops.fn_html(COALESCE(ec.title, e.code)), N' (', COUNT(*), N')</h3>',
                          CASE WHEN ec.howToFix IS NOT NULL THEN N'<p><i>' + ops.fn_html(ec.howToFix) + N'</i></p>' ELSE N'' END,
                          N'<table><tr><th>Store(s)</th><th>Item</th><th>Detail</th></tr>',
                          STRING_AGG(CAST(CONCAT(N'<tr><td>',
                              ops.fn_html(COALESCE(JSON_VALUE(e.detail, '$.stores'),
                                                   RIGHT('0' + CAST(e.locId AS varchar(3)), 2), N'–')),
                              N'</td><td>', ISNULL(CAST(e.itemId AS nvarchar(12)), N''),
                              N'</td><td>', ops.fn_html(e.message), N'</td></tr>') AS nvarchar(max)), N'')
                              WITHIN GROUP (ORDER BY e.itemId, e.locId),
                          N'</table>') AS sect
            FROM ops.run_event e LEFT JOIN ops.event_code ec ON ec.code = e.code
            WHERE e.runId = @runId AND e.severity = 'WARN'
            GROUP BY COALESCE(ec.title, e.code), ec.howToFix) g);

    DECLARE @digestHtml nvarchar(max) = CONCAT(@style,
        N'<p><b>', ops.fn_html(@domainName), N'</b> found ', @warnCount, N' exception(s) on the run started ', @runDate,
        N'. Menus were still published; these items need attention in InfoGenesis.</p>',
        @digestSections, @footer);

    DECLARE @digestSlackText nvarchar(1000) = CONCAT(N':warning: *', @domainName, N'* – ', @warnCount,
        CASE WHEN @warnCount = 1 THEN N' exception' ELSE N' exceptions' END, N' today',
        CASE WHEN @warnBreakdown IS NOT NULL THEN N' (' + @warnBreakdown + N')' ELSE N'' END,
        N'. Details emailed to ', @emailTo, N'.');

    SELECT
        @runId AS runId, @domainCode AS domainCode, @areaCode AS areaCode,
        @slackSecret AS slackSecretName, @emailTo AS emailTo,
        CAST(CASE WHEN @errCount  > 0 THEN 1 ELSE 0 END AS bit) AS sendAlert,
        CAST(CASE WHEN @warnCount > 0 THEN 1 ELSE 0 END AS bit) AS sendDigest,
        @alertSubject AS alertSubject,
        @digestSubject AS digestSubject,
        (SELECT @alertSlackText AS [text] FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS slackAlertBody,
        (SELECT @digestSlackText AS [text] FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS slackDigestBody,
        ops.fn_graph_mail(@alertSubject, @alertHtml, @emailTo, @replyTo) AS graphAlertBody,
        ops.fn_graph_mail(@digestSubject, @digestHtml, @emailTo, @replyTo) AS graphDigestBody;
END
GO

/* ---------- Watchdog ----------
   Run by the separate pl_ops_watchdog pipeline (9:30 AM ET). Catches the case where a
   pipeline never ran at all. Logs FEED_LATE events under its own run, then returns one
   row per area with late feeds that has not already been notified today.
   ADF: usp_run_start -> usp_watchdog -> ForEach row: Slack + email -> usp_log_notification -> usp_run_end */
CREATE OR ALTER PROCEDURE ops.usp_watchdog
    @runId varchar(64)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT ops.run_event (runId, domainCode, severity, step, locId, code, message, detail)
    SELECT @runId, h.domainCode, 'ERROR', N'watchdog', NULLIF(h.locId, 0), 'FEED_LATE',
           CONCAT(h.feedCode,
                  CASE WHEN h.locId > 0 THEN N' for store ' + RIGHT('0' + CAST(h.locId AS varchar(3)), 2) ELSE N'' END,
                  CASE WHEN h.lastArrivedUtc IS NULL THEN N' has never arrived'
                       ELSE CONCAT(N' last arrived ', FORMAT(ops.fn_eastern(h.lastArrivedUtc), 'ddd M/d h:mm tt', 'en-US'),
                                   N' ET (', CAST(h.ageHours AS decimal(6,1)), N' h ago; limit ', h.maxAgeHours, N' h)') END),
           (SELECT h.feedCode AS feedCode, h.maxAgeHours AS maxAgeHours, h.lastArrivedUtc AS lastArrivedUtc,
                   h.lastRunId AS lastRunId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM ops.v_feed_health h
    WHERE h.isLate = 1
      AND NOT EXISTS (   -- already alerted today by the domain's own pipeline (e.g. FILE_MISSING at the retry)
          SELECT 1 FROM ops.run_event x
          WHERE x.domainCode = h.domainCode AND ISNULL(x.locId, 0) = h.locId AND x.severity = 'ERROR'
            AND x.loggedUtc >= DATEADD(HOUR, -12, SYSUTCDATETIME()));

    DECLARE @todayEt date = CAST(ops.fn_eastern(SYSUTCDATETIME()) AS date);
    DECLARE @runDate nvarchar(40) = FORMAT(ops.fn_eastern(SYSUTCDATETIME()), 'ddd MMM d, h:mm tt', 'en-US') + N' ET';

    WITH late AS (
        SELECT d.areaCode, e.domainCode, d.displayName, e.locId, e.message, ec.howToFix
        FROM ops.run_event e
        JOIN ops.domain d ON d.domainCode = e.domainCode
        LEFT JOIN ops.event_code ec ON ec.code = e.code
        WHERE e.runId = @runId AND e.code = 'FEED_LATE'
    ), byArea AS (
        SELECT a.areaCode, a.slackSecretName, a.emailTo, COALESCE(a.emailReplyTo, a.emailTo) AS replyTo,
               COUNT(*) AS n,
               CONCAT(N'[ALERT][', a.areaCode, N'] Watchdog – ', COUNT(*), N' late feed(s)') AS subject,
               STRING_AGG(CAST(CONCAT(N'<tr><td>', ops.fn_html(l.displayName), N'</td><td>',
                    ops.fn_html(l.message), N'</td><td>', ops.fn_html(ISNULL(l.howToFix, N'')), N'</td></tr>')
                    AS nvarchar(max)), N'') AS rowsHtml,
               STRING_AGG(CAST(l.message AS nvarchar(max)), N'; ') AS plain
        FROM late l JOIN ops.area a ON a.areaCode = l.areaCode
        GROUP BY a.areaCode, a.slackSecretName, a.emailTo, COALESCE(a.emailReplyTo, a.emailTo)
    )
    SELECT b.areaCode, b.slackSecretName, b.emailTo, b.subject,
           (SELECT CONCAT(N':rotating_light: *Watchdog* – ', b.n, N' late feed(s): ', LEFT(b.plain, 600),
                          N'. Details emailed to ', b.emailTo, N'.') AS [text]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS slackBody,
           ops.fn_graph_mail(b.subject,
               CONCAT(N'<style>body{font-family:Segoe UI,Arial,sans-serif;font-size:14px}table{border-collapse:collapse}',
                      N'td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}th{background:#f2f2f2}</style>',
                      N'<p>These feeds have not arrived within their expected window (checked ', @runDate, N').</p>',
                      N'<table><tr><th>Process</th><th>Problem</th><th>What to do</th></tr>', b.rowsHtml, N'</table>',
                      N'<p style="color:#777;font-size:12px">SELECT * FROM ops.v_feed_health WHERE isLate = 1</p>'),
               b.emailTo, b.replyTo) AS graphBody
    FROM byArea b
    WHERE NOT EXISTS (   -- one watchdog notification per area per day
        SELECT 1 FROM ops.notification n
        WHERE n.areaCode = b.areaCode AND n.kind = 'watchdog' AND n.status = 'sent'
          AND CAST(ops.fn_eastern(n.sentUtc) AS date) = @todayEt);
END
GO

/* ---------- Retention ----------
   Called at the end of the watchdog pipeline. Temporal history is purged by SQL Server itself
   (HISTORY_RETENTION_PERIOD on each ig table). */
CREATE OR ALTER PROCEDURE ops.usp_purge
    @keepMonths int = 13
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cutoff datetime2(0) = DATEADD(MONTH, -@keepMonths, SYSUTCDATETIME());
    DECLARE @n int = 1;
    WHILE @n > 0
    BEGIN
        DELETE TOP (5000) FROM ops.run_event WHERE loggedUtc < @cutoff;
        SET @n = @@ROWCOUNT;
    END
    DELETE FROM ops.notification WHERE sentUtc < @cutoff;
    DELETE FROM ops.feed_arrival WHERE arrivedUtc < @cutoff;
    DELETE FROM ops.pipeline_run WHERE startedUtc < @cutoff;
END
GO
