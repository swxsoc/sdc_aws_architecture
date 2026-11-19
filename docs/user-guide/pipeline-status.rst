.. _pipeline-status:

Pipeline Status Dashboard
=========================

The ``swxsoc-pipeline-status`` CloudWatch dashboard answers one question at a
glance: is every mission's data pipeline healthy right now? It is modelled on
a public system-status page, with one group per mission workspace, one row per
pipeline stage, a status glyph and word for each, and a list of recent events.
It stays inside AWS: the page is rendered by a Lambda-backed *custom widget*
and viewed in the CloudWatch console, so nothing is published outside the
account.

Where it comes from
-------------------

The pipeline root gives every ``<env>-<mission>`` workspace a set of health
alarms named ``<env><mission-slug>-pipeline-*`` and a composite alarm
``<env><mission-slug>-pipeline-unhealthy`` (``dev-`` prefixes development
workspaces; production names have no prefix). The status widget reads only
those alarms:

* every ``*-pipeline-unhealthy`` composite alarm identifies a workspace, so a
  mission appears on the dashboard as soon as its health alarms exist, with no
  change to the widget;
* each remaining alarm of the workspace is mapped to a stage by its name
  suffix, together with what its ALARM state means (an *issue*: errors or
  slowness while data still flows, or an *outage*: data is not getting
  through);
* ``DescribeAlarmHistory`` supplies the recent events.

.. list-table:: Alarm suffix to stage
   :header-rows: 1
   :widths: 18 52 15

   * - Stage
     - Alarms (suffix after ``<env><mission-slug>-pipeline-``)
     - ALARM means
   * - Landing
     - ``unsorted-incoming-objects``
     - Outage
   * - Sorting
     - ``sorting-{errors,throttles,duration,log-errors}``
     - Issue
   * - Notification
     - ``<instrument>-topic-delivery-failures``, ``<instrument>-queue-age``
     - Outage
   * - Processing
     - ``processing-{errors,throttles,duration,log-errors}``;
       ``missing-metatracker-rows``
     - Issue; Outage
   * - Artifacts
     - ``artifacts-{errors,throttles,duration,log-errors}``;
       ``missing-timestream-records``
     - Issue; Outage
   * - Concatenation
     - ``concating-{errors,throttles,duration,log-errors}``
     - Issue
   * - Reconciliation
     - ``reconciliation-not-running``, ``reconciliation-errors``,
       ``reconciliation-check-errors``
     - Issue

How a status is decided
-----------------------

* A **stage** shows the worst of its alarms: *Outage* beats *Issue*.
  *No data* appears only when every alarm of the stage is
  ``INSUFFICIENT_DATA`` (typically a workspace whose reconciliation job has
  not run yet). *Not enabled* means the workspace has no alarms for that stage,
  for example concatenation on a mission without a concating Lambda.
* A **mission** shows the worst of its stages, and opens expanded whenever it
  is not fully available.
* The **summary** at the top counts available stages, current outages, current
  issues and stages without data, in the manner of "Available services / N
  current outages / N current issues".
* **Recent events** pairs each alarm's transitions to ALARM and back to OK
  into "Resolved · start – end" rows, newest first, or "Ongoing · since" for
  alarms still firing. An alarm that has been in ALARM for longer than the
  history window is listed as ongoing from its own state-change time.

Stage rows link to the alarm in the CloudWatch console and mission titles link
to the mission's own ``<env><mission-slug>-pipeline`` dashboard, which holds
the metric graphs for drilling down.

Terraform
---------

The dashboard lives in the deployment root (``deployment-infrastructure-terraform``),
the only root without per-environment workspaces, because one dashboard covers
both environments. ``status_dashboard.tf`` creates, when
``enable_pipeline_status_dashboard = true``:

* the widget Lambda ``swxsoc-pipeline-status-widget``
  (``lambda/status_widget/widget.py``, Python 3.12, arm64, no third-party
  dependencies) with a role that may only ``cloudwatch:DescribeAlarms`` and
  ``cloudwatch:DescribeAlarmHistory``;
* the dashboard ``swxsoc-pipeline-status`` with a header and one custom widget
  per environment (Production above Development), both updating on dashboard
  refresh and resize;
* the IAM policy ``swxsoc-pipeline-status-viewer``, which grants
  ``cloudwatch:GetDashboard`` on that dashboard and ``lambda:InvokeFunction``
  on the widget. A custom widget runs with the viewer's own credentials, so
  attach this policy to the console role or group of everyone who should see
  the page; identities are managed outside the repository.

The flag defaults to ``false`` and the resources are additive only. Outputs
``pipeline_status_dashboard_url`` and ``pipeline_status_viewer_policy_arn``
give the console link and the policy to attach. ``pipeline_status_history_days``
(default 14), ``pipeline_status_widget_height`` (default 24 grid rows; the
widget scrolls) and ``pipeline_status_log_retention_days`` (default 14) tune
it.

Operating notes
---------------

* The widget follows the console theme (dark or light) through the
  ``widgetContext`` the dashboard passes it.
* Turn on the dashboard's auto-refresh to keep the page current; each refresh
  invokes the widget once per environment. The data is alarm state, so it is
  never fresher than the alarms' five-minute evaluation periods.
* Until a workspace has its health alarms applied, its environment shows a
  "no mission pipelines are reporting yet" panel rather than an empty page.
* If the widget cannot read CloudWatch (missing permission, throttling), it
  renders an error panel with the exception instead of failing the dashboard.

Development
-----------

``make status-widget-test`` runs the unit tests, which cover workspace
discovery, every alarm classification, status precedence, history pairing and
both themes without any AWS access. ``python preview.py <dir>`` in the widget
directory writes sample pages for a browser, and the codestyle workflow lints
the sources with ruff and runs the tests.
