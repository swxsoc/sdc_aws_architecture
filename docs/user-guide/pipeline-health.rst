.. _pipeline-health:

Pipeline Health
===============

Every mission pipeline is a chain of five stages that each leave a different
kind of evidence behind. Until this feature existed, none of that evidence was
watched: a stage could stop working and the only way to notice was to go
looking for files that should have been there. This page records what each
stage proves about itself, what used to alarm (nothing), where each stage fails
silently, and the feedback loop the pipeline root now builds for every mission
workspace.

The chain, for one file
-----------------------

#. **Land.** An uploader puts a file into ``<env>-<mission>-swsoc-incoming``.
   S3 invokes the sorting Lambda for the object.
#. **Sort.** ``<env>-<mission>_sdc_aws_sorting_lambda_function`` parses the
   filename, copies the object into ``<env>-<mission>-<instrument>`` under
   ``<level>/<yyyy>/<mm>/<dd>/`` (or ``<level>/<descriptor>/...`` above the
   first level), verifies the copy, **deletes the incoming object**, posts a
   comms notification and writes a Timestream row (``source_bucket`` =
   incoming, ``new_file_key`` = the sorted key). An EventBridge schedule also
   sweeps the whole incoming bucket every 12 hours and re-sorts anything whose
   name parses and whose sorted copy is missing.
#. **Notify.** Each instrument bucket has one S3 notification per data level
   prefix that publishes to ``<env>-<mission>-<instrument>-sns-topic``. The
   topic fans out to the processing Lambda, the artifacts Lambda, and the
   instrument's SQS queue (that subscription was made outside Terraform; an
   external consumer drains the queue).
#. **Process.** ``<env>-<mission>_sdc_aws_processing_lambda_function``
   imports ``<package>.calibration.process_file``, uploads each product next to
   the input, and writes MetaTracker rows to the RDS table
   ``<mission>_science_file`` (one for the input, one per product) plus a
   ``<mission>_status`` row (``success``, ``pending`` or ``failed``).
#. **Record.** ``<env>-<mission>_sdc_aws_artifacts_lambda_function`` posts the
   processed-file notification and writes a Timestream row (``file_key`` = the
   full object key, ``destination_bucket`` = the instrument bucket). It runs for
   every object the topic announces, so products get a row too.

Where the chain is blind today
------------------------------

The table below was built from the Lambda sources, the swxsoc library, and the
live PADRE workspace (read-only) on 2026-11-09. "Alarm today" is what existed
in the account before this feature: twelve CloudTrail alarms and a website
health check, none of them about the pipeline.

.. list-table::
   :header-rows: 1
   :widths: 12 30 10 48

   * - Stage
     - Evidence that it ran
     - Alarm today
     - Silent failure
   * - Land
     - The object exists in the incoming bucket; ``AWS/Lambda Invocations``
       on the sorting function.
     - none
     - Nothing records that a file arrived, so a stopped uploader looks the
       same as a quiet day. A file dropped into the wrong mission's incoming
       bucket (a PADRE file sits in the HERMES bucket since 2025-07) is never
       noticed.
   * - Sort
     - The incoming object is gone and the sorted copy exists; a Timestream
       row with ``source_bucket`` = incoming; a log line ``File ...
       Successfully Moved``.
     - none
     - The handler catches every exception and returns a 500 body, so
       ``AWS/Lambda Errors`` stays at zero (it did for the whole week
       inspected while the log shows errors). A filename the parser rejects
       is logged (``Issue parsing file``) and left in the bucket forever; the
       12-hourly sweep skips it too. HERMES still has level-0 files from
       2023 in its incoming bucket.
   * - Notify
     - ``AWS/SNS NumberOfMessagesPublished`` per topic; ``AWS/SQS
       NumberOfMessagesSent`` / ``Received`` per queue.
     - none
     - A failed delivery to a Lambda (``NumberOfNotificationsFailed``) is
       retried by SNS and then dropped. If the external queue consumer stops,
       messages age out after four days with no signal.
   * - Process
     - The product object next to the input; MetaTracker rows; a log line
       ``File ... processed successfully`` with the row ids.
     - none
     - The handler returns 500 on any exception, so no Lambda error. An
       instrument package that fails to import, a calibration that raises, or
       a MetaTracker write that fails (a ``ForeignKeyViolation`` was in the
       PADRE log) all end as ``ERROR:`` log lines only. The MetaTracker writer
       swallows its own exceptions and returns ``(None, None)``, which is how
       106 production PADRE files ended up with no row until a manual replay.
       A file that no calibration can process is recorded as ``failed`` and
       never looked at again unless an empty event triggers ``fetch_data``.
   * - Record
     - A Timestream row with ``file_key`` = the object key; a comms post.
     - none
     - The handler returns 500 on any exception and logs it as a
       ``{'status': 'ERROR', ...}`` line (``Error Processing Artifacts`` is
       only in the response it returns, never in the log); a Timestream
       client that cannot be created is only logged, in the same form. Comms
       errors use that form too, are logged on every PADRE file (the Slack
       token lacks a scope) and are harmless to the data record, which is why
       they are excluded from the alarm below.
   * - Whole chain
     - Only by hand: list a bucket, query the database, query Timestream and
       compare.
     - none
     - No job compared the three records, so a stage that stopped writing one
       of them was invisible until someone needed the data.

The feedback loop
-----------------

Everything below is created by the pipeline root for each ``<env>-<mission>``
workspace. It is additive: no existing bucket, topic, queue, Lambda, role or
policy changes. Two variables gate it, both on by default because they only
create new resources:

``enable_pipeline_alarms`` (default ``true``)
  The alert topic, the per-stage alarms, the log metric filters, the composite
  alarm and the dashboard.

``enable_pipeline_reconciliation`` (default ``true``)
  The reconciliation Lambda, its schedule, its metrics and the alarms on them.

Nothing is *delivered* anywhere until a mission opts in:

``pipeline_alert_emails`` (default ``[]``)
  Email addresses subscribed to the alert topic. Each address must confirm the
  subscription that SNS mails it.

``enable_pipeline_alerts_mattermost`` (default ``false``)
  Posts every alarm transition to the mission's Mattermost channel through a
  small notifier Lambda that reuses the mission's existing Mattermost secret.
  Requires ``enable_mattermost``.

Alert topic
~~~~~~~~~~~

``<env>-<mission>-pipeline-alerts`` receives the ALARM and OK transitions of
every alarm below, so a subscriber learns which stage broke, not only that
something did. The composite alarm notifies the same topic.

Alarms
~~~~~~

All alarm names start with ``<env>-<mission>-pipeline-``. Each alarm evaluates
one five-minute period unless noted, and treats missing data as healthy, so a
quiet pipeline is not an alarming one.

.. list-table::
   :header-rows: 1
   :widths: 30 40 30

   * - Alarm
     - Condition
     - Closes which gap
   * - ``<stage>-errors``
     - ``AWS/Lambda Errors`` > 0 for sorting, processing, artifacts, and
       concating where it exists.
     - Crashes outside the handlers' try blocks (import-time failures, out
       of memory, timeouts).
   * - ``<stage>-throttles``
     - ``AWS/Lambda Throttles`` > 0.
     - Events dropped because the account ran out of concurrency.
   * - ``<stage>-duration``
     - ``AWS/Lambda Duration`` maximum above
       ``pipeline_lambda_duration_alarm_fraction`` (default 0.9) of the
       function timeout.
     - A stage about to be killed mid-file. The PADRE processing maximum over
       the week inspected was 398 s of a 900 s timeout.
   * - ``<stage>-log-errors``
     - A metric filter on each Lambda log group counts failure lines; > 0
       alarms. Sorting: ``Issue parsing file``, ``Error sorting file``,
       ``does not exist in bucket``. Processing: ``Error Processing Event``
       and any ``'status': 'ERROR'`` line. Artifacts: any
       ``'status': 'ERROR'`` line that does not contain ``comms client``,
       ``Slack``, ``slack``, ``Mattermost``, ``mattermost`` or
       ``message_ts``. Concating: ``ERROR:`` and ``Traceback``.
     - The exceptions the handlers swallow. This is the alarm that would have
       fired on the MetaTracker foreign-key failure.
   * - ``<instrument>-topic-delivery-failures``
     - ``AWS/SNS NumberOfNotificationsFailed`` > 0 per instrument topic.
     - A processing or artifacts Lambda that SNS could not invoke.
   * - ``<instrument>-queue-age``
     - ``AWS/SQS ApproximateAgeOfOldestMessage`` above
       ``pipeline_sqs_oldest_message_age_threshold_seconds`` (default six
       hours) per instrument queue.
     - The external queue consumer has stopped.
   * - ``unsorted-incoming-objects``
     - Reconciliation metric ``UnsortedIncomingObjects`` > 0.
     - A file landed and is still in the incoming bucket after the grace
       period: the sorting stage did not act on it.
   * - ``missing-metatracker-rows``
     - Reconciliation metric ``MissingMetaTrackerRows`` > 0.
     - A file in an instrument bucket that the processing Lambda never
       recorded. The 106-file PADRE backlog would have alarmed within an hour
       of the first missing row.
   * - ``missing-timestream-records``
     - Reconciliation metric ``MissingTimestreamRecords`` > 0.
     - A file in an instrument bucket that neither sorting nor artifacts
       logged, so the topic fan-out or the artifacts stage failed.
   * - ``reconciliation-check-errors``
     - Reconciliation metric ``ReconciliationCheckErrors`` > 0.
     - The reconciliation itself could not reach S3, RDS or Timestream, so its
       other metrics must not be trusted.
   * - ``reconciliation-not-running``
     - Reconciliation metric ``ReconciliationRuns`` absent for two scheduled
       periods (missing data breaches).
     - The schedule or the Lambda stopped; the pipeline is unwatched.
   * - ``unhealthy`` (composite)
     - Any alarm above in ALARM.
     - One switch for "this mission's pipeline needs attention", for the
       dashboard and for anyone who wants a single subscription.

Reconciliation
~~~~~~~~~~~~~~

``<env>-<mission>_pipeline_reconciliation`` is a Python 3.12 Lambda built from
``pipeline-infrastructure-terraform/lambda/reconciliation``. It runs on
``pipeline_reconciliation_schedule`` (default every hour) and looks back
``pipeline_reconciliation_window_hours`` (default 24) while ignoring anything
newer than ``pipeline_reconciliation_grace_minutes`` (default 60), which is
the time the chain is allowed to still be working on a file. It checks real
objects, not metrics:

* lists the incoming bucket: every object older than the grace period and
  inside the window, except keys matching
  ``pipeline_reconciliation_ignore_key_regex`` (defaults to directory markers,
  ``index.html`` and ``list.js``), is **unsorted**. Objects older than the
  window are reported as ``IncomingBacklogObjects`` for the dashboard only, so
  historical leftovers are visible without alarming forever;
* lists every instrument bucket and keeps the objects under a data-level
  prefix (the ones S3 announces to the topic) that are older than the grace
  period and inside the window;
* queries ``<mission>_science_file`` for those objects by filename stem and by
  key, and counts the ones with no row as ``MissingMetaTrackerRows``. It also
  reports ``FailedProcessingFiles``, the ``<mission>_status`` rows marked
  ``failed`` in the window, for the dashboard;
* queries the mission's Timestream table over the window and counts objects
  that appear in neither ``file_key`` nor ``new_file_key`` as
  ``MissingTimestreamRecords``;
* publishes those numbers plus ``ReconciledObjects``,
  ``IncomingObjectsInWindow``, ``ReconciliationRuns`` and
  ``ReconciliationCheckErrors`` to the namespace
  ``SWxSOC/Pipeline/<env>-<mission>``, and logs every affected key so the
  CloudWatch log doubles as the replay list. The run summary carries at most
  200 keys per check; the complete lists follow it as ``affected_keys``
  entries (``unsorted``, ``missing_metatracker``, ``missing_timestream``),
  split into numbered batches of about 100 KB so each fits one log event.

The window must cover the run interval plus the grace period
(``pipeline_reconciliation_window_hours * 60 >=
pipeline_reconciliation_interval_minutes +
pipeline_reconciliation_grace_minutes``), and Terraform rejects a
configuration that does not. Otherwise an object too fresh to judge at one
run would already be outside the window at the next and would never be
checked.

The RDS security group admits only the Lambda and Grafana security groups, so
the reconciliation Lambda joins the mission's Lambda security group and
subnets whenever ``enable_lambda_vpc`` is true, exactly like the processing
Lambda. It reads the mission's RDS secret and speaks the PostgreSQL wire
protocol itself (``pgwire.py``, MD5 and SCRAM-SHA-256 authentication), because
the managed Python runtime ships no PostgreSQL driver and the repository does
not vendor one. The connection is always TLS with the server verified, the
equivalent of ``sslmode=verify-full``: the certificate must chain to an Amazon
RDS root and match the endpoint's host name before the user name or password
is sent, and a server that refuses TLS is refused. The RDS roots are in no
public trust store, so ``rds-global-bundle.pem`` (an unmodified copy of
https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) is packaged
with the Lambda; replace it with a fresh download if AWS adds a region or a
root. A failed verification is a ``metatracker`` check error, which raises
the ``reconciliation-check-errors`` alarm. When
``enable_lambda_vpc`` is false the database check is skipped and said so in
the log; the S3 and Timestream checks still run.

Dashboard
~~~~~~~~~

``<env>-<mission>-pipeline`` shows the chain left to right: incoming objects
in the window and the backlog, sorting invocations, errors and log errors,
per-instrument topic deliveries and queue depth, processing invocations,
errors, duration and log errors, artifacts and concating the same way, the
reconciliation metrics, and the state of every alarm in this list.

Operating it
------------

* **Turn delivery on for a mission** by adding to its tfvars, for example::

      pipeline_alert_emails           = ["soc-oncall@example.org"]
      enable_pipeline_alerts_mattermost = true

  and applying the workspace. Nothing else changes.
* **A manual full apply is needed once per workspace.** The image deployment
  builds apply a targeted plan for one Lambda only and refuse anything else,
  so the health resources are created by ``terraform apply -var-file=...``
  with the current image tags, reviewed like any other change.
* **When ``missing-metatracker-rows`` fires**, the reconciliation log lists
  each key. Reprocess them with the processing Lambda (an SNS-shaped event per
  key, as the MetaTracker replay did) and the next run clears the alarm.
* **When ``unsorted-incoming-objects`` fires**, the log lists the keys. Either
  the name is not one the mission's parser accepts, or the sorting Lambda
  failed on it; its ``log-errors`` alarm says which.
* **Expected noise.** ``FailedProcessingFiles`` is a dashboard metric, not an
  alarm, because a calibration that declines a file is recorded as failed by
  design. Comms (Slack and Mattermost) errors in the artifacts log are not
  counted either.

Development
-----------

The Terraform lives in ``pipeline-infrastructure-terraform/pipeline_health.tf``
and is covered by the ``plan_pipeline_health_*`` runs in ``basic.tftest.hcl``
and an assertion in ``production.tftest.hcl``. The Lambda sources are under
``pipeline-infrastructure-terraform/lambda/`` and are zipped by the
``archive`` provider at plan time (the ``build/`` output is ignored by git).
Their unit tests run with ``make lambda-test`` and in the codestyle workflow,
which also runs ruff over them. ``pgwire.py`` was verified against a real
PostgreSQL 16 for MD5, SCRAM-SHA-256 and cleartext authentication, since the
managed test providers cannot reach a database. ``test_pgwire.py`` covers the
TLS handling with a fake server: a server that refuses TLS, a certificate
outside the trusted roots and a trusted certificate for another host name are
each rejected before any credential is sent.

Known gaps
----------

* A **processing failure that is recorded correctly** (a ``failed`` status row)
  is visible on the dashboard but does not alarm. Whether that should page
  someone is a per-mission decision; the metric is there to alarm on.
* The reconciliation proves a **product file exists for an input** only
  indirectly (the product has its own rows). It does not know which inputs
  should have produced products, because that is instrument-package logic.
* The **external SQS consumer** is not managed here; the queue-age alarm
  reports that it has stopped, nothing more.
* **Dev workspaces** with the Grafana EC2 or operator traffic are not
  distinguished from prod; the thresholds are the same everywhere.
* The scheduled **demo smoke test** stays demo-only. A per-mission synthetic
  upload would write into live mission buckets, so it is not part of this
  feature.
