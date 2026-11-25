.. _pipeline-status:

Pipeline Status Dashboard
=========================

The ``swxsoc-pipeline-status`` CloudWatch dashboard answers one question at a
glance: is every mission's data pipeline healthy right now? It is modelled on
a public system-status page and written for the whole team, not only for cloud
engineers: a one-sentence verdict first ("HERMES has not been getting data
through for 8 days. PADRE has errors (data still flowing) for 4 h. iMPAX is
fine."), then one group per mission with the problem named in its header, one
row per pipeline step in plain words, and for every firing alarm a
plain-language headline with direct links to the log lines, the alarm and the
resource involved. It stays inside AWS: the page is rendered by a Lambda-backed
*custom widget* and viewed in the CloudWatch console, so nothing is published
outside the account.

Where it comes from
-------------------

The pipeline root gives every ``<env>-<mission>`` workspace a set of health
alarms (see :ref:`pipeline-health`) named ``<env><mission-slug>-pipeline-*`` and a composite alarm
``<env><mission-slug>-pipeline-unhealthy`` (``dev-`` prefixes development
workspaces; production names have no prefix). The status widget reads those
alarms and, for one line per mission, the health check's own metrics:

* every ``*-pipeline-unhealthy`` composite alarm identifies a workspace, so a
  mission appears on the dashboard as soon as its health alarms exist, with no
  change to the widget;
* each remaining alarm of the workspace is mapped to a stage by its name
  suffix, together with what its ALARM state means (an *issue*: errors or
  slowness while data still flows, or an *outage*: data is not getting
  through);
* ``DescribeAlarmHistory`` supplies the recent events;
* one ``GetMetricData`` call per environment reads the latest health-check
  counts of every mission from its ``SWxSOC/Pipeline/<env>-<mission-slug>``
  namespace (``IncomingObjectsInWindow``, ``ReconciledObjects``,
  ``MissingMetaTrackerRows``, ``MissingTimestreamRecords`` and
  ``FailedProcessingFiles``, each the Maximum over the last reconciliation
  period, which the widget takes from the alarms' period). These feed the
  "Last 24 h" line only; nothing else depends on them.

.. list-table:: Alarm suffix to stage
   :header-rows: 1
   :widths: 18 52 15

   * - Step shown (technical name)
     - Alarms (suffix after ``<env><mission-slug>-pipeline-``)
     - ALARM means
   * - Arrival (Landing)
     - ``unsorted-incoming-objects``
     - Outage
   * - Sorting
     - ``sorting-{errors,throttles,duration,log-errors}``
     - Issue
   * - Hand-off (Notification)
     - ``<instrument>-topic-delivery-failures``; ``<instrument>-queue-age``
     - Outage; Issue (the queue is drained by an external consumer, SWxSOC
       processing runs from the topic)
   * - Processing
     - ``processing-{errors,throttles,duration,log-errors}``;
       ``missing-metatracker-rows``
     - Issue; Outage
   * - Recording (Artifacts)
     - ``artifacts-{errors,throttles,duration,log-errors}``;
       ``missing-timestream-records``
     - Issue; Outage
   * - Daily files (Concatenation)
     - ``concating-{errors,throttles,duration,log-errors}``
     - Issue
   * - Health check (Reconciliation)
     - ``reconciliation-not-running``, ``reconciliation-errors``,
       ``reconciliation-check-errors``
     - Issue

How a status is decided
-----------------------

* A **step** shows the worst of its alarms: *Outage* (data is not getting
  through this step) beats *Issue* (errors on some files, data still getting
  through). *Not checked yet* appears only when every alarm of the step is
  ``INSUFFICIENT_DATA`` (typically a workspace whose health check has not run
  yet). Steps the mission does not have (daily files on a mission without a
  concating Lambda) are folded into one "is not part of this mission's
  pipeline" line.
* A **mission** shows the worst of its evaluated steps; steps that are not
  checked yet do not count against it. Missions are ordered worst first and
  only missions with a problem start expanded. The header names the problem
  and how long it has lasted ("Outage · Files arrived but were not sorted into
  instrument buckets · 8 days").
* The **verdict band** at the top says in one sentence which missions are not
  getting data through, which have errors, and which are fine, followed by one
  line per problem and when it was last checked.
* The **daily counts line** under each mission header ("Last 24 h: 142 files
  arrived · 140 checked · 0 missing records · 2 failed processing") is what
  the latest health-check run counted: files that landed in the incoming
  bucket inside the reconciliation window (24 h by default), files it checked
  against MetaTracker and Timestream, the missing records of both kinds added
  together, and the processing status rows marked failed. It is shown
  collapsed or expanded. "0 files arrived" stays in the muted colour because
  it is not a status: a quiet day and a stopped uploader look the same to the
  pipeline, which is what its tooltip says. A mission whose health check has
  not published yet has no line, and if the metrics cannot be read the page
  renders without the lines rather than failing.
* Every **firing alarm** renders as a block with a plain-language headline, the
  latest value in words ("3,612 files", "2 in the last 5 min", "waiting 2.5 h"),
  when it started, and pill links: the log group filtered to the lines that
  raised the alarm (the Lambda's log for its errors, the health-check log for
  the affected-file lists), the alarm itself, the topic, queue or bucket
  involved, and a "What to do" note. Log links are derived from the
  ``FunctionName``, ``TopicName`` and ``QueueName`` dimensions the alarms carry,
  so they need no extra permissions. The ``unsorted-incoming-objects`` alarm
  gets an "Incoming bucket" pill when its description names the bucket
  ("... > 0 in bucket <name>; ..."), which the pipeline root writes because
  the bucket name does not always follow the mission's (HERMES lands in
  ``swsoc-incoming``); an alarm applied before that description change simply
  has no pill.
* **Recent events** pairs each alarm's transitions to ALARM and back to OK
  into "<day> · lasted <time>" rows, newest first, or "Ongoing · <time>" for
  alarms still firing, each with the reason recorded at the time and a log
  link for that window. An alarm that has been in ALARM for longer than the
  history window is listed as ongoing from its own state-change time.

Mission headers carry "Graphs" (the mission's own
``<env><mission-slug>-pipeline`` dashboard with the metric graphs) and
"All alarms" links.

Terraform
---------

The dashboard lives in the deployment root (``deployment-infrastructure-terraform``),
the only root without per-environment workspaces, because one dashboard covers
both environments. ``status_dashboard.tf`` creates, when
``enable_pipeline_status_dashboard = true``:

* the widget Lambda ``swxsoc-pipeline-status-widget``
  (``lambda/status_widget/widget.py``, Python 3.12, arm64, no third-party
  dependencies) with a role that may only ``cloudwatch:DescribeAlarms``,
  ``cloudwatch:DescribeAlarmHistory`` and ``cloudwatch:GetMetricData`` (none
  of them resource-scoped; the role writes nothing but its own log);
* the dashboard ``swxsoc-pipeline-status`` with a header and one custom widget
  per environment (Production above Development), both updating on dashboard
  refresh and resize;
* the IAM policy ``swxsoc-pipeline-status-viewer``, which grants
  ``cloudwatch:GetDashboard`` on that dashboard and ``lambda:InvokeFunction``
  on the widget. A custom widget runs with the viewer's own credentials, so
  attach this policy to the console role or group of everyone who should see
  the page; identities are managed outside the repository.

The flag defaults to ``true`` (set it to ``false`` to remove the dashboard); the resources are additive only and the deployment root is applied by hand. Outputs
``pipeline_status_dashboard_url`` and ``pipeline_status_viewer_policy_arn``
give the console link and the policy to attach. ``pipeline_status_history_days``
(default 14), ``pipeline_status_widget_height`` (default 24 grid rows; the
widget scrolls) and ``pipeline_status_log_retention_days`` (default 14) tune
it. ``pipeline_status_contact`` (default empty) adds a "Questions about an
outage: ..." line at the foot of the page.

Operating notes
---------------

* The widget follows the console theme (dark or light) through the
  ``widgetContext`` the dashboard passes it.
* Turn on the dashboard's auto-refresh to keep the page current; each refresh
  invokes the widget once per environment. The data is alarm state, so it is
  never fresher than the alarms' five-minute evaluation periods; the daily
  counts line is as fresh as the last health-check run (hourly by default).
* Until a workspace has its health alarms applied, its environment shows a
  "no mission pipelines are reporting yet" panel rather than an empty page.
* If the widget cannot read CloudWatch (missing permission, throttling), it
  renders an error panel with the exception instead of failing the dashboard.

Development
-----------

``make lambda-test`` runs the unit tests, which cover workspace
discovery, every alarm classification, status precedence, history pairing,
the daily counts (query batching, parsing, wording and the degraded page)
and both themes without any AWS access, using a fake CloudWatch client. ``python preview.py <dir>`` in the widget
directory writes sample pages for a browser, and the codestyle workflow lints
the sources with ruff and runs the tests.
