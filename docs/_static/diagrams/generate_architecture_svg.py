#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SWxSOC AWS Architecture diagram generator.

This script renders ``swxsoc_aws_architecture.svg`` from the declarative data
in the CONFIG section below. To update the diagram, edit the LANES / NODES /
EDGES lists and re-run:

    python3 generate_architecture_svg.py

No third-party dependencies are required (pure standard library). The output is
a self-contained SVG that renders identically in browsers, Sphinx HTML docs,
and presentation tools.
"""
import os
import xml.etree.ElementTree as ET

# --------------------------------------------------------------------------
# Palette (AWS-flavored)
# --------------------------------------------------------------------------
INK      = "#232F3E"   # AWS "squid ink"
INK_SOFT = "#3B4759"
PAPER_A  = "#fbfcfe"
PAPER_B  = "#eef2f8"
CARD     = "#ffffff"
CARD_BRD = "#d4dbe6"
TX       = "#1d2733"
TX_SUB   = "#5d6b7d"

# Category accent colors (stroke / text) and gradient stops (icon fills)
CAT = {
    "repo":    {"a": "#5b6b81", "g": ("#67768c", "#3d4a5e")},
    "build":   {"a": "#3b7dd8", "g": ("#5a97e6", "#2c63b4")},  # developer tools (blue)
    "registry":{"a": "#ec7211", "g": ("#ff9d4d", "#d35400")},  # containers / ECR (orange)
    "s3":      {"a": "#3fa45b", "g": ("#5cbf78", "#1f7a3d")},  # storage (green)
    "db":      {"a": "#4150d6", "g": ("#6573ec", "#2c34a8")},  # database (indigo)
    "event":   {"a": "#8c4fff", "g": ("#a677ff", "#6a2fd6")},  # app integration (purple)
    "secret":  {"a": "#dd344c", "g": ("#f0586e", "#b51f37")},  # security (red)
    "lambda":  {"a": "#ed7100", "g": ("#ff9d2e", "#cf5b00")},  # compute (orange)
    "ext":     {"a": "#4e79a7", "g": ("#6e96bf", "#3a5f86")},  # external (steel blue)
    "slack":   {"a": "#6b2f7a", "g": ("#9a4ca8", "#5a1f66")},
    "grafana": {"a": "#f06a1f", "g": ("#ff9442", "#d4540f")},
    "log":     {"a": "#0e7c86", "g": ("#2aa7b3", "#0a5b63")},  # log shipping / Loki
    "ec2":     {"a": "#ec7211", "g": ("#ff9d4d", "#d35400")},  # EC2 compute
}

# Edge flow colors
FLOW = {
    "build":  "#c2410c",
    "event":  "#7c3aed",
    "secret": "#c02644",
    "data":   "#2f855a",
    "ext":    "#2e73b8",
    "alert":  "#d6321a",
    "ops":    "#7c8aa0",
}

FONT = "'Segoe UI','Helvetica Neue',Helvetica,Arial,sans-serif"

# --------------------------------------------------------------------------
# Layout constants
# --------------------------------------------------------------------------
W = 2440
MARGIN = 46
CONTENT_L = 150
CONTENT_R = 2290
LANE_L = 116
LANE_R = 2324
LANE_TITLE_H = 50      # space reserved at top of a lane band for its title
GAP = 76               # vertical gap between lanes (room for routed labels)
LANE_TOP = 322

# Right/left routing gutters (clear vertical channels)
GUT_R1 = 2206
GUT_R2 = 2266
GUT_L1 = 150
GUT_L2 = 184

# --------------------------------------------------------------------------
# CONFIG: lanes
# --------------------------------------------------------------------------
LANES = [
    dict(key="repo",   title="Repository",              sub="source code & infrastructure definitions",        cat="repo",  h=142),
    dict(key="build",  title="Build & Image",           sub="CodeBuild pipelines & ECR image registries",      cat="build", h=150),
    dict(key="event",  title="Event & Configuration",   sub="file events, schedules & runtime secrets",        cat="event", h=150),
    dict(key="run",    title="Lambda Container Runtime", sub="containerized Lambda functions",                  cat="lambda",h=158),
    dict(key="data",   title="Data & State",            sub="science outputs, file state & time-series",       cat="s3",    h=142),
    dict(key="ext",    title="External Integration",    sub="mission packages, shared helpers & external services", cat="ext", h=164),
    dict(key="ops",    title="Observability & Operations", sub="notifications & dashboards",                   cat="slack", h=148),
]

# compute lane y positions
laney = {}
_lh = {L["key"]: L["h"] for L in LANES}
_y = LANE_TOP
for L in LANES:
    laney[L["key"]] = _y
    _y += L["h"] + GAP

def gap_below(k):
    """y-coordinate of the channel just below lane k (mid of the gap)."""
    return laney[k] + _lh[k] + GAP / 2.0

def lane_top_pad(k, pad=14):
    return laney[k] - pad
REGION_BOT = _y - GAP + 26
REGION_TOP = 232
CLOUD_TOP = 168
CLOUD_BOT = REGION_BOT + 92        # leave room for legend inside cloud
# Separate "fleet & inventory" section beneath the AWS Cloud
FLEET_TOP = CLOUD_BOT + 48
FLEET_H = 290
FLEET_BOT = FLEET_TOP + FLEET_H
H = FLEET_BOT + MARGIN

# --------------------------------------------------------------------------
# CONFIG: nodes
#   cx = horizontal center, w = width, lines = 1 or 2 (height derived)
#   icon = category key for the glyph/gradient
# --------------------------------------------------------------------------
def N(id, lane, cx, w, icon, title, sub="", lines=2):
    return dict(id=id, lane=lane, cx=cx, w=w, icon=icon, title=title, sub=sub, lines=lines)

NODES = [
    # Repository lane
    N("r_base",  "repo", 430,  364, "repo", "Base image repos",   "sdc_aws_base_docker_image (+ swxsoc_pipeline)"),
    N("r_pkgs",  "repo", 920,  364, "repo", "Shared packages",    "swxsoc · swxsoc_reach · sdc_aws_utils"),
    N("r_lam",   "repo", 1410, 364, "repo", "Lambda repos (6)",   "sorting · processing · … · alert"),
    N("r_dep",   "repo", 1900, 364, "repo", "Deployment / IaC repo", "sdc_aws_architecture (Terraform)"),

    # Build & image lane
    N("b_cbbase","build", 430,  364, "build",    "CodeBuild — base",   "shared base image build"),
    N("b_pubecr","build", 920,  364, "registry", "Public ECR",         "shared base image"),
    N("b_cblam", "build", 1410, 364, "build",    "CodeBuild — Lambdas","per-function image builds"),
    N("b_pvtecr","build", 1900, 364, "registry", "Private ECR",        "Lambda runtime images"),

    # Event & configuration lane
    N("e_s3in",  "event", 430,  360, "s3",     "Incoming S3 buckets", "instrument file uploads"),
    N("e_sns",   "event", 945,  300, "event",  "SNS topics",          "object-created (+ SQS)"),
    N("e_eb",    "event", 1410, 330, "event",  "EventBridge",         "scheduled rules"),
    N("e_sec",   "event", 1880, 320, "secret", "Secrets Manager",     "Grafana + RDS creds"),

    # Lambda runtime lane (6 containerized functions)
    N("l_sort",  "run", 328,  322, "lambda", "Sorting Lambda",    "route files to buckets"),
    N("l_proc",  "run", 685,  322, "lambda", "Processing Lambda", "calibrate · write state"),
    N("l_conc",  "run", 1042, 322, "lambda", "Concating Lambda",  "daily roll-up"),
    N("l_art",   "run", 1398, 322, "lambda", "Artifacts Lambda",  "notify · log activity"),
    N("l_exec",  "run", 1755, 322, "lambda", "Executor Lambda",   "scheduled imports"),
    N("l_alert", "run", 2112, 322, "lambda", "Alert Lambda",      "GOES flux → alerts"),

    # Data & state lane
    N("d_s3",    "data", 560,  380, "s3", "Instrument / processed S3", "sorted & calibrated products"),
    N("d_rds",   "data", 1220, 380, "db", "CDFTracker DB",            "RDS · file state & lineage"),
    N("d_ts",    "data", 1755, 380, "db", "Amazon Timestream",        "metrics · GOES · log signals"),

    # External integration lane
    N("x_reach", "ext", 328,  300, "ext", "REACH / UDL",         "sdc_aws_reach_sync → incoming"),
    N("x_inst",  "ext", 685,  300, "ext", "Instrument packages", "HERMES · PADRE · IMPAX"),
    N("x_utils", "ext", 1042, 300, "ext", "sdc_aws_utils",       "shared AWS helpers"),
    N("x_goes",  "ext", 1398, 300, "ext", "NOAA GOES",           "X-ray flux"),
    N("x_stix",  "ext", 1755, 300, "ext", "STIX",                "data center"),
    N("x_gcn",   "ext", 2112, 300, "ext", "GCN",                 "Kafka alert stream"),

    # Observability & operations lane
    N("o_slack",    "ops", 560,  380, "slack",   "Slack",          "pipeline notifications"),
    N("o_promtail", "ops", 1220, 380, "log",     "Promtail → Loki","ships CloudWatch/S3 logs"),
    N("o_graf",     "ops", 1755, 380, "grafana", "Grafana",        "dashboards & annotations"),
]

NODE = {n["id"]: n for n in NODES}

# derive node geometry (top-left x/y, width, height)
for n in NODES:
    n["h"] = 88 if n["lines"] == 2 else 66
    y0 = laney[n["lane"]] + LANE_TITLE_H
    band = next(L for L in LANES if L["key"] == n["lane"])
    avail = band["h"] - LANE_TITLE_H
    n["y"] = y0 + (avail - n["h"]) / 2.0
    n["x"] = n["cx"] - n["w"] / 2.0

def anchor(id, side):
    n = NODE[id]
    x, y, w, h = n["x"], n["y"], n["w"], n["h"]
    if side == "b": return (x + w/2, y + h)
    if side == "t": return (x + w/2, y)
    if side == "l": return (x, y + h/2)
    if side == "r": return (x + w, y + h/2)
    if side == "bl": return (x + w*0.30, y + h)
    if side == "br": return (x + w*0.70, y + h)
    if side == "tl": return (x + w*0.30, y)
    if side == "tr": return (x + w*0.70, y)
    raise ValueError(side)

# --------------------------------------------------------------------------
# CONFIG: edges
#   each edge: from anchor -> list of waypoints. 'pts' built from a/b anchors
#   plus optional 'via' absolute waypoints. label sits at 'lbl' point or auto.
# --------------------------------------------------------------------------
def E(a, b, flow, label="", via=None, dash=False, lblpos=0.5, emph=False):
    return dict(a=a, b=b, flow=flow, label=label, via=via or [], dash=dash, lblpos=lblpos, emph=emph)

def _A(id, s):  # convenience: absolute anchor point
    return anchor(id, s)

# vertical routing channels (clear gaps between cards in the Data / External lanes)
CH_INST = 790    # data gap 750..1030, drops into x_inst
CH_UTILS = 970   # data gap 750..1030, drops into x_utils
CH_SNS = 863     # threads l_proc/l_conc gap up to SNS
CH_GOES = 1520   # data gap 1410..1630
CH_STIX = 2150   # right of Timestream
CH_GRAF = 1933   # ext gap x_stix..x_gcn
FARL_UP = 138    # far-left rail (REACH upload, going up)
FARL_DN = 162    # far-left rail (Slack, going down)

EDGES = [
    # ---- repo -> build ----
    E(("r_base","b"),  ("b_cbbase","t"), "build"),
    E(("r_pkgs","b"),  ("b_cblam","t"),  "build", "package deps"),
    E(("r_lam","b"),   ("b_cblam","t"),  "build"),

    # ---- build chain (intra-lane, left to right) ----
    E(("b_cbbase","r"),("b_pubecr","l"), "build", "push"),
    E(("b_pubecr","r"),("b_cblam","l"),  "build", "FROM base"),
    E(("b_cblam","r"), ("b_pvtecr","l"), "build", "push"),

    # ---- deployed images: Private ECR -> runtime (right gutter) ----
    E(("b_pvtecr","b"),("l_alert","t"),  "build", "deployed images",
      via=[(_A("b_pvtecr","b")[0], gap_below("build")), (GUT_R1, gap_below("build")),
           (GUT_R1, lane_top_pad("run")), (_A("l_alert","t")[0], lane_top_pad("run"))]),
    # ---- IaC provisions infra: deployment repo -> runtime (outer right gutter) ----
    E(("r_dep","r"), ("l_alert","tr"),   "ops", "Terraform apply", dash=True,
      via=[(GUT_R2, _A("r_dep","r")[1]), (GUT_R2, lane_top_pad("run", 28)),
           (_A("l_alert","tr")[0], lane_top_pad("run", 28))], lblpos=0.32),

    # ---- trigger chain: incoming -> Sorting -> instrument buckets -> SNS -> Processing/Artifacts ----
    E(("e_s3in","b"), ("l_sort","t"), "event", "object created", emph=True),
    E(("l_sort","b"), ("d_s3","t"),   "data",  "sorted files"),
    E(("d_s3","r"),   ("e_sns","t"),  "event", "sorted-file events", dash=True,
      via=[(CH_SNS, _A("d_s3","r")[1]), (CH_SNS, lane_top_pad("event")),
           (_A("e_sns","t")[0], lane_top_pad("event"))], lblpos=0.12),
    E(("e_sns","b"),  ("l_proc","t"), "event", "triggers Processing", emph=True),
    E(("e_sns","br"), ("l_art","t"),  "event", ""),

    # ---- schedules ----
    E(("e_eb","bl"), ("l_conc","t"),  "event", "daily 01:00"),
    E(("e_eb","b"),  ("l_exec","t"),  "event", "noon UTC"),
    E(("e_eb","br"), ("l_alert","t"), "event", ""),

    # ---- secrets ----
    E(("e_sec","b"), ("l_exec","t"),  "secret", "secrets / env", dash=True),

    # ---- runtime -> data & state ----  (targets are self-labeled; arrows carry the flow)
    E(("l_proc","bl"), ("d_s3","tr"),  "data", "processed files"),
    E(("l_proc","b"),  ("d_rds","t"),  "data", ""),
    E(("l_conc","b"),  ("d_rds","tl"), "data", ""),
    E(("l_art","bl"),  ("d_rds","tr"), "data", ""),
    E(("l_exec","b"),  ("d_ts","t"),   "data", "GOES → Timestream"),

    # ---- runtime -> external (channels skirt the Data lane) ----
    E(("l_proc","bl"), ("x_inst","t"), "ext", "",
      via=[(_A("l_proc","bl")[0], gap_below("run")), (CH_INST, gap_below("run")),
           (CH_INST, lane_top_pad("ext")), (_A("x_inst","t")[0], lane_top_pad("ext"))]),
    E(("l_proc","b"),  ("x_utils","t"),"ext", "",
      via=[(_A("l_proc","b")[0], gap_below("run")), (CH_UTILS, gap_below("run")),
           (CH_UTILS, lane_top_pad("ext")), (_A("x_utils","t")[0], lane_top_pad("ext"))]),
    E(("l_exec","bl"), ("x_goes","t"), "ext", "import GOES flux",
      via=[(_A("l_exec","bl")[0], gap_below("run")), (CH_GOES, gap_below("run")),
           (CH_GOES, lane_top_pad("ext")), (_A("x_goes","t")[0], lane_top_pad("ext"))]),
    E(("l_exec","br"), ("x_stix","t"), "ext", "scheduled ingest",
      via=[(_A("l_exec","br")[0], gap_below("run")), (CH_STIX, gap_below("run")),
           (CH_STIX, lane_top_pad("ext")), (_A("x_stix","t")[0], lane_top_pad("ext"))], lblpos=0.84),
    E(("l_alert","b"), ("x_gcn","t"),  "alert", "alert messages"),

    # ---- upstream ingest: REACH/UDL uploads into the incoming buckets ----
    E(("x_reach","l"), ("e_s3in","t"), "ext", "uploads",
      via=[(FARL_UP, _A("x_reach","l")[1]), (FARL_UP, lane_top_pad("event")),
           (_A("e_s3in","t")[0], lane_top_pad("event"))], lblpos=0.55),

    # ---- observability ----
    E(("l_sort","b"), ("o_slack","t"), "ops", "Slack notifications",
      via=[(_A("l_sort","b")[0], gap_below("run")), (FARL_DN, gap_below("run")),
           (FARL_DN, lane_top_pad("ops")), (_A("o_slack","t")[0], lane_top_pad("ops"))], lblpos=0.14),
    E(("d_ts","b"),   ("o_graf","t"),  "data", "dashboards",
      via=[(_A("d_ts","b")[0], gap_below("data")), (CH_GRAF, gap_below("data")),
           (CH_GRAF, lane_top_pad("ops")), (_A("o_graf","t")[0], lane_top_pad("ops"))], lblpos=0.5),
    E(("o_promtail","r"), ("o_graf","l"), "data", "logs → Loki"),
]

# --------------------------------------------------------------------------
# SVG helpers
# --------------------------------------------------------------------------
def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def rounded_path(pts, r=16):
    """Orthogonal-ish polyline through pts with rounded corners."""
    pts = [(round(x, 1), round(y, 1)) for x, y in pts]
    if len(pts) == 2:
        return "M{} {} L{} {}".format(pts[0][0], pts[0][1], pts[1][0], pts[1][1])
    d = "M{} {}".format(pts[0][0], pts[0][1])
    for i in range(1, len(pts) - 1):
        p0, p1, p2 = pts[i - 1], pts[i], pts[i + 1]
        # vector in
        v1 = (p1[0] - p0[0], p1[1] - p0[1])
        v2 = (p2[0] - p1[0], p2[1] - p1[1])
        l1 = max((v1[0] ** 2 + v1[1] ** 2) ** 0.5, 0.001)
        l2 = max((v2[0] ** 2 + v2[1] ** 2) ** 0.5, 0.001)
        rr = min(r, l1 / 2, l2 / 2)
        a = (p1[0] - v1[0] / l1 * rr, p1[1] - v1[1] / l1 * rr)
        b = (p1[0] + v2[0] / l2 * rr, p1[1] + v2[1] / l2 * rr)
        d += " L{} {} Q{} {} {} {}".format(round(a[0], 1), round(a[1], 1),
                                            p1[0], p1[1], round(b[0], 1), round(b[1], 1))
    d += " L{} {}".format(pts[-1][0], pts[-1][1])
    return d

OUT = []
def add(s): OUT.append(s)

# --------------------------------------------------------------------------
# Icon glyphs (white, drawn inside a 0..48 box)
# --------------------------------------------------------------------------
def glyph(kind):
    w = '#ffffff'
    if kind == "repo":
        return ('<path d="M14 11h15a3 3 0 0 1 3 3v23H17a3 3 0 0 1-3-3V11z" fill="none" stroke="%s" stroke-width="2.4"/>'
                '<path d="M19 18h11M19 24h11M19 30h7" stroke="%s" stroke-width="2.6" stroke-linecap="round"/>' % (w, w))
    if kind == "build":
        return ('<circle cx="24" cy="24" r="8.4" fill="none" stroke="%s" stroke-width="2.6"/>'
                '<path d="M24 9v5M24 34v5M9 24h5M34 24h5M13.5 13.5l3.5 3.5M31 31l3.5 3.5M34.5 13.5L31 17M17 31l-3.5 3.5" stroke="%s" stroke-width="2.4" stroke-linecap="round"/>' % (w, w))
    if kind == "registry":
        return ('<rect x="11" y="11" width="26" height="8" rx="1.6" fill="%s"/>'
                '<rect x="11" y="21.5" width="26" height="8" rx="1.6" fill="%s" opacity="0.85"/>'
                '<rect x="11" y="32" width="17" height="7" rx="1.6" fill="%s" opacity="0.7"/>' % (w, w, w))
    if kind == "s3":
        return ('<path d="M12 14h24l-2.4 22a2 2 0 0 1-2 1.8H16.4a2 2 0 0 1-2-1.8L12 14z" fill="none" stroke="%s" stroke-width="2.5" stroke-linejoin="round"/>'
                '<path d="M12.7 20h22.6" stroke="%s" stroke-width="2.4"/>' % (w, w))
    if kind == "db":
        return ('<ellipse cx="24" cy="13.5" rx="12" ry="4.2" fill="none" stroke="%s" stroke-width="2.5"/>'
                '<path d="M12 13.5v21c0 2.3 5.4 4.2 12 4.2s12-1.9 12-4.2v-21" fill="none" stroke="%s" stroke-width="2.5"/>'
                '<path d="M12 24c0 2.3 5.4 4.2 12 4.2s12-1.9 12-4.2" fill="none" stroke="%s" stroke-width="2.2"/>' % (w, w, w))
    if kind == "event":
        return ('<circle cx="15" cy="24" r="3.4" fill="%s"/>'
                '<circle cx="34" cy="14" r="3.4" fill="%s"/>'
                '<circle cx="34" cy="24" r="3.4" fill="%s"/>'
                '<circle cx="34" cy="34" r="3.4" fill="%s"/>'
                '<path d="M18 24h6M30.6 15.4 24 24M30.6 32.6 24 24M27 24h3.6" stroke="%s" stroke-width="2.2" stroke-linecap="round"/>' % (w, w, w, w, w))
    if kind == "secret":
        return ('<circle cx="20" cy="19" r="6.6" fill="none" stroke="%s" stroke-width="2.6"/>'
                '<path d="M24.4 23.4 36 35M31 30l3.4-3.4M34 33l3-3" stroke="%s" stroke-width="2.6" stroke-linecap="round"/>' % (w, w))
    if kind == "lambda":
        return ('<path d="M16 11h7l13 26h-7.4l-9.6-19.6L24 28l-4.6 9H12L16 11z" fill="%s"/>' % w)
    if kind == "ext":
        return ('<circle cx="24" cy="24" r="13" fill="none" stroke="%s" stroke-width="2.5"/>'
                '<path d="M11 24h26M24 11v26" stroke="%s" stroke-width="2.1"/>'
                '<path d="M24 11c5 4.5 5 21.5 0 26M24 11c-5 4.5-5 21.5 0 26" fill="none" stroke="%s" stroke-width="2.1"/>' % (w, w, w))
    if kind == "slack":
        return ('<path d="M19 14v20M29 14v20M14 19h20M14 29h20" stroke="%s" stroke-width="3.1" stroke-linecap="round"/>' % w)
    if kind == "grafana":
        return ('<path d="M12 35 21 24l6 5 9-13" fill="none" stroke="%s" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>'
                '<circle cx="21" cy="24" r="2.6" fill="%s"/><circle cx="27" cy="29" r="2.6" fill="%s"/>' % (w, w, w))
    if kind == "log":
        return ('<path d="M13 13h22M13 20h16M13 27h22M13 34h13" stroke="%s" stroke-width="2.7" stroke-linecap="round"/>' % w)
    if kind == "ec2":
        return ('<rect x="15" y="15" width="18" height="18" rx="2.5" fill="none" stroke="%s" stroke-width="2.4"/>'
                '<rect x="20" y="20" width="8" height="8" rx="1.2" fill="%s"/>'
                '<path d="M19 15v-4M24 15v-4M29 15v-4M19 33v4M24 33v4M29 33v4M15 19h-4M15 24h-4M15 29h-4M33 19h4M33 24h4M33 29h4" stroke="%s" stroke-width="2" stroke-linecap="round"/>' % (w, w, w))
    return ''

# --------------------------------------------------------------------------
# Build SVG
# --------------------------------------------------------------------------
add('<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
    'viewBox="0 0 {W} {H}" font-family="{F}" role="img" aria-labelledby="ttl dsc">'.format(W=W, H=H, F=FONT))
add('<title id="ttl">SWxSOC AWS Architecture</title>')
add('<desc id="dsc">Lane-based AWS architecture diagram for SWxSOC: repositories build Lambda '
    'container images, AWS events invoke runtime functions, and science outputs feed storage, '
    'state, alerts and dashboards.</desc>')

# ---- defs ----
add('<defs>')
add('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>'.format(a=PAPER_A, b=PAPER_B))
for k, v in CAT.items():
    g0, g1 = v["g"]
    add('<linearGradient id="ic-{k}" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>'.format(k=k, a=g0, b=g1))
# title accent
add('<linearGradient id="accent" x1="0" y1="0" x2="1" y2="0">'
    '<stop offset="0" stop-color="#ec7211"/><stop offset="1" stop-color="#ff9d2e"/></linearGradient>')
# soft card shadow
add('<filter id="shadow" x="-20%" y="-20%" width="140%" height="150%">'
    '<feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#1b2a44" flood-opacity="0.16"/></filter>')
add('<filter id="cloudshadow" x="-5%" y="-5%" width="110%" height="115%">'
    '<feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#1b2a44" flood-opacity="0.10"/></filter>')
# dot pattern
add('<pattern id="dots" width="34" height="34" patternUnits="userSpaceOnUse">'
    '<circle cx="2" cy="2" r="1.2" fill="#c7d2e0" opacity="0.32"/></pattern>')
# arrow markers per flow
for name, col in FLOW.items():
    add('<marker id="ar-{n}" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7.5" markerHeight="7.5" orient="auto-start-reverse">'
        '<path d="M0 0 10 5 0 10 2.6 5z" fill="{c}"/></marker>'.format(n=name, c=col))
add('</defs>')

# ---- background ----
add('<rect width="{W}" height="{H}" fill="url(#bg)"/>'.format(W=W, H=H))
add('<rect width="{W}" height="{H}" fill="url(#dots)"/>'.format(W=W, H=H))

# ---- title block ----
add('<rect x="{x}" y="56" width="64" height="40" rx="7" fill="{ink}"/>'.format(x=MARGIN+8, ink=INK))
add('<text x="{x}" y="83" font-size="20" font-weight="700" fill="#ff9d2e" text-anchor="middle">aws</text>'.format(x=MARGIN+8+32))
add('<text x="{x}" y="90" font-size="46" font-weight="800" fill="{tx}" letter-spacing="0.3">SWxSOC AWS Architecture</text>'.format(x=MARGIN+88, tx=INK))
add('<rect x="{x}" y="104" width="232" height="6" rx="3" fill="url(#accent)"/>'.format(x=MARGIN+90))
add('<text x="{x}" y="136" font-size="19" fill="{sub}">Container build pipeline and runtime data flow: source repos build Lambda images, '
    'AWS events invoke containers, and science outputs feed storage, state, alerts and dashboards.</text>'.format(x=MARGIN+90, sub=TX_SUB))

# ---- AWS Cloud boundary ----
add('<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="22" fill="#ffffff" stroke="{ink}" stroke-width="2.4" filter="url(#cloudshadow)"/>'.format(
    x=MARGIN+6, y=CLOUD_TOP, w=W-2*(MARGIN+6), h=CLOUD_BOT-CLOUD_TOP, ink=INK))
add('<rect x="{x}" y="{y}" width="148" height="34" rx="7" fill="{ink}"/>'.format(x=MARGIN+28, y=CLOUD_TOP+18, ink=INK))
add('<text x="{x}" y="{y}" font-size="17" font-weight="700" fill="#ffffff">AWS Cloud</text>'.format(x=MARGIN+44, y=CLOUD_TOP+41))
# region boundary
add('<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="none" stroke="#2296b7" stroke-width="2" stroke-dasharray="11 8"/>'.format(
    x=LANE_L-22, y=REGION_TOP, w=(LANE_R+22)-(LANE_L-22), h=REGION_BOT-REGION_TOP))
add('<rect x="{x}" y="{y}" width="34" height="34" rx="7" fill="#2296b7"/>'.format(x=LANE_L-8, y=REGION_TOP+14))
add('<text x="{x}" y="{y}" font-size="16" font-weight="700" fill="#14748d">Region</text>'.format(x=LANE_L+34, y=REGION_TOP+30))
add('<text x="{x}" y="{y}" font-size="14" fill="#5a7a86">SWxSOC runtime account &amp; delivery path</text>'.format(x=LANE_L+108, y=REGION_TOP+30))

# ---- lanes ----
def tint(hexcol, amt):
    """lighten hex toward white by amt (0..1)"""
    h = hexcol.lstrip('#')
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    r = int(r + (255 - r) * amt); g = int(g + (255 - g) * amt); b = int(b + (255 - b) * amt)
    return "#%02x%02x%02x" % (r, g, b)

# Lane bands + accent bars are drawn first (background). The lane TITLES are
# drawn later, AFTER the edges, on an opaque masking chip so connectors route
# cleanly behind the labels and never appear on top of the title text.
for L in LANES:
    y = laney[L["key"]]
    a = CAT[L["cat"]]["a"]
    add('<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{f}" stroke="{s}" stroke-width="1.5"/>'.format(
        x=LANE_L, y=y, w=LANE_R-LANE_L, h=L["h"], f=tint(a, 0.90), s=tint(a, 0.45)))
    add('<rect x="{x}" y="{y}" width="7" height="{h}" rx="3.5" fill="{a}"/>'.format(x=LANE_L+0, y=y, h=L["h"], a=a))

def draw_lane_titles():
    for L in LANES:
        y = laney[L["key"]]
        a = CAT[L["cat"]]["a"]
        title_w = 11.6 * len(L["title"])
        sub_w = 7.4 * len(L["sub"])
        chip_x = LANE_L + 12
        chip_w = (LANE_L + 26 + title_w + 18 + sub_w + 12) - chip_x
        # opaque masking chip (same fill as the band) hides any line behind the label
        add('<rect x="{x}" y="{cy}" width="{w}" height="30" rx="8" fill="{f}"/>'.format(
            x=chip_x, cy=y + 11, w=chip_w, f=tint(a, 0.90)))
        add('<text x="{x}" y="{ty}" font-size="20" font-weight="700" fill="{tx}">{t}</text>'.format(
            x=LANE_L+26, ty=y+32, tx=INK, t=esc(L["title"])))
        add('<text x="{x}" y="{ty}" font-size="13.5" fill="{sub}">{s}</text>'.format(
            x=LANE_L+26+title_w+18, ty=y+31, sub=TX_SUB, s=esc(L["sub"])))

# ---- edges (drawn before nodes so nodes sit on top of line ends) ----
def fill_via_y(e):
    """Build the polyline for an edge: source anchor, explicit waypoints, target anchor."""
    ax, ay = anchor(*e["a"])
    bx, by = anchor(*e["b"])
    if e["via"]:
        pts = [(ax, ay)] + [(p[0], p[1]) for p in e["via"]] + [(bx, by)]
    else:
        sa, sb = e["a"][1], e["b"][1]
        if sa in ("b", "bl", "br") and sb in ("t", "tl", "tr"):
            my = (ay + by) / 2.0
            pts = [(ax, ay)] if abs(ax - bx) < 1 else [(ax, ay), (ax, my), (bx, my)]
            pts.append((bx, by))
        elif sa == "r" and sb == "l":
            if abs(ay - by) < 1:
                pts = [(ax, ay), (bx, by)]
            else:
                mx = (ax + bx) / 2.0
                pts = [(ax, ay), (mx, ay), (mx, by), (bx, by)]
        else:
            my = (ay + by) / 2.0
            pts = [(ax, ay), (ax, my), (bx, my), (bx, by)]
    out = [pts[0]]
    for p in pts[1:]:
        if abs(p[0]-out[-1][0]) > 0.5 or abs(p[1]-out[-1][1]) > 0.5:
            out.append(p)
    return out

def pt_on(pts, frac):
    # length-parameterized point
    segs = []
    total = 0
    for i in range(len(pts)-1):
        l = ((pts[i+1][0]-pts[i][0])**2 + (pts[i+1][1]-pts[i][1])**2)**0.5
        segs.append(l); total += l
    target = total*frac; acc = 0
    for i in range(len(pts)-1):
        if acc+segs[i] >= target:
            t = (target-acc)/max(segs[i], 0.001)
            return (pts[i][0]+(pts[i+1][0]-pts[i][0])*t, pts[i][1]+(pts[i+1][1]-pts[i][1])*t)
        acc += segs[i]
    return pts[-1]

label_boxes = []
for e in EDGES:
    pts = fill_via_y(e)
    col = FLOW[e["flow"]]
    dash = ' stroke-dasharray="9 7"' if e["dash"] else ''
    d = rounded_path(pts, 18)
    if e["emph"]:
        # primary "trigger" path: soft halo + heavier stroke so the kickoff stands out
        add('<path d="{d}" fill="none" stroke="{c}" stroke-width="9" opacity="0.16" '
            'stroke-linejoin="round" stroke-linecap="round"/>'.format(d=d, c=col))
        add('<path d="{d}" fill="none" stroke="{c}" stroke-width="3.8"{dash} '
            'marker-end="url(#ar-{f})" stroke-linejoin="round" stroke-linecap="round"/>'.format(
                d=d, c=col, dash=dash, f=e["flow"]))
    else:
        add('<path d="{d}" fill="none" stroke="{c}" stroke-width="2.4"{dash} '
            'marker-end="url(#ar-{f})" stroke-linejoin="round" stroke-linecap="round"/>'.format(
                d=d, c=col, dash=dash, f=e["flow"]))
    if e["label"]:
        lx, ly = pt_on(pts, e["lblpos"])
        label_boxes.append((lx, ly, e["label"], col, e["emph"]))

# lane titles drawn AFTER edges, on masking chips (connectors route behind labels)
draw_lane_titles()

# label pills on top
for lx, ly, text, col, emph in label_boxes:
    if emph:
        wpx = 8.4 * len(text) + 30
        add('<g>'
            '<rect x="{x}" y="{y}" width="{w}" height="26" rx="13" fill="{c}"/>'
            '<circle cx="{dx}" cy="{ty}" r="3.1" fill="#ffffff"/>'
            '<text x="{tx}" y="{tty}" font-size="13.5" font-weight="700" fill="#ffffff" text-anchor="middle">{t}</text>'
            '</g>'.format(x=lx-wpx/2, y=ly-13, w=wpx, c=col, dx=lx-wpx/2+15, ty=ly,
                          tx=lx+7, tty=ly+4.6, t=esc(text)))
    else:
        wpx = 7.4 * len(text) + 18
        add('<g>'
            '<rect x="{x}" y="{y}" width="{w}" height="22" rx="11" fill="#ffffff" stroke="{c}" stroke-width="1.1" opacity="0.97"/>'
            '<text x="{tx}" y="{ty}" font-size="12.5" font-weight="600" fill="{c}" text-anchor="middle">{t}</text>'
            '</g>'.format(x=lx-wpx/2, y=ly-11, w=wpx, c=col, tx=lx, ty=ly+4.2, t=esc(text)))

# ---- nodes ----
def draw_node(n):
    x, y, w, h = n["x"], n["y"], n["w"], n["h"]
    a = CAT[n["icon"]]["a"]
    add('<g filter="url(#shadow)">')
    add('<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="13" fill="{card}" stroke="{brd}" stroke-width="1.4"/>'.format(
        x=x, y=y, w=w, h=h, card=CARD, brd=CARD_BRD))
    add('<rect x="{x}" y="{y}" width="6" height="{h}" rx="3" fill="{a}"/>'.format(x=x, y=y, h=h, a=a))
    add('</g>')
    # icon (48-unit glyph box scaled to isz)
    isz = 50
    ix, iy = x + 20, y + (h - isz) / 2.0
    sc = isz / 48.0
    add('<g transform="translate({ix},{iy}) scale({sc})">'.format(ix=round(ix,1), iy=round(iy,1), sc=round(sc,4)))
    add('<rect width="48" height="48" rx="11" fill="url(#ic-{k})"/>'.format(k=n["icon"]))
    add('<rect width="48" height="48" rx="11" fill="none" stroke="#ffffff" stroke-opacity="0.28" stroke-width="1"/>')
    add(glyph(n["icon"]))
    add('</g>')
    tx = ix + isz + 16
    if n["lines"] == 2:
        add('<text x="{tx}" y="{ty}" font-size="16.5" font-weight="700" fill="{c}">{t}</text>'.format(
            tx=tx, ty=y + h/2 - 5, c=TX, t=esc(n["title"])))
        add('<text x="{tx}" y="{ty}" font-size="13" fill="{c}">{s}</text>'.format(
            tx=tx, ty=y + h/2 + 15, c=TX_SUB, s=esc(n["sub"])))
    else:
        add('<text x="{tx}" y="{ty}" font-size="16.5" font-weight="700" fill="{c}">{t}</text>'.format(
            tx=tx, ty=y + h/2 + 6, c=TX, t=esc(n["title"])))

for n in NODES:
    draw_node(n)

# ---- legend ----
ly = REGION_BOT + 26
legend = [
    ("build",  "Build / containers"),
    ("event",  "Events"),
    ("secret", "Secrets"),
    ("data",   "S3 / data state"),
    ("ext",    "External services"),
    ("alert",  "Alerts"),
]
lx = LANE_L + 4
add('<text x="{x}" y="{y}" font-size="14.5" font-weight="700" fill="{ink}">Legend</text>'.format(x=lx, y=ly+16, ink=INK))
lx += 96
for flow, text in legend:
    col = FLOW.get(flow, CAT.get(flow, {}).get("a", "#777"))
    add('<rect x="{x}" y="{y}" width="26" height="14" rx="4" fill="{c}"/>'.format(x=lx, y=ly+3, c=col))
    add('<text x="{x}" y="{y}" font-size="14" fill="{tx}">{t}</text>'.format(x=lx+34, y=ly+15, tx=TX, t=esc(text)))
    lx += 56 + 8.2 * len(text)

# --------------------------------------------------------------------------
# Deployment fleet & inventory — a modest separate section showing what the
# logical pipeline actually runs as in the account (EC2 fleet, the full set of
# Lambda functions, and the ECR image inventory).
# --------------------------------------------------------------------------
def draw_fleet():
    px, pw = MARGIN + 6, W - 2 * (MARGIN + 6)
    add('<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="20" fill="#f3f6fb" stroke="#9fb0c3" stroke-width="1.8"/>'.format(
        x=px, y=FLEET_TOP, w=pw, h=FLEET_H))
    add('<rect x="{x}" y="{y}" width="334" height="34" rx="8" fill="{ink}"/>'.format(x=px + 26, y=FLEET_TOP + 20, ink=INK))
    add('<text x="{x}" y="{y}" font-size="17" font-weight="700" fill="#ffffff">Deployment Fleet &amp; Inventory</text>'.format(x=px + 42, y=FLEET_TOP + 43))
    add('<text x="{x}" y="{y}" font-size="14" fill="{sub}">the logical pipeline above is realized by this fleet — runtime account · us-east-1</text>'.format(
        x=px + 380, y=FLEET_TOP + 43, sub=TX_SUB))

    cy = FLEET_TOP + 78
    ch = FLEET_H - 78 - 26
    gap = 24
    cw = (pw - 60 - 3 * gap) / 4.0
    cx0 = px + 30

    def card(i, icon, title, lines):
        cx = cx0 + i * (cw + gap)
        a = CAT[icon]["a"]
        add('<g filter="url(#shadow)">'
            '<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="13" fill="#ffffff" stroke="{brd}" stroke-width="1.4"/>'
            '<rect x="{x}" y="{y}" width="6" height="{h}" rx="3" fill="{a}"/></g>'.format(
                x=cx, y=cy, w=cw, h=ch, brd=CARD_BRD, a=a))
        isz = 46
        ix, iy = cx + 22, cy + 18
        add('<g transform="translate({ix},{iy}) scale({sc})">'
            '<rect width="48" height="48" rx="11" fill="url(#ic-{k})"/>'
            '<rect width="48" height="48" rx="11" fill="none" stroke="#ffffff" stroke-opacity="0.28" stroke-width="1"/>{g}</g>'.format(
                ix=ix, iy=iy, sc=round(isz / 48.0, 3), k=icon, g=glyph(icon)))
        add('<text x="{x}" y="{y}" font-size="18" font-weight="700" fill="{tx}">{t}</text>'.format(
            x=ix + isz + 14, y=cy + 41, tx=TX, t=esc(title)))
        yy = cy + 82
        for txt, style in lines:
            if style == "b":
                add('<text x="{x}" y="{y}" font-size="14.5" font-weight="700" fill="{c}">{t}</text>'.format(
                    x=cx + 24, y=yy, c=TX, t=esc(txt))); yy += 25
            elif style == "m":
                add('<text x="{x}" y="{y}" font-size="13" fill="{c}">{t}</text>'.format(
                    x=cx + 40, y=yy, c=TX_SUB, t=esc(txt))); yy += 23
            else:
                add('<text x="{x}" y="{y}" font-size="13.5" fill="{c}">{t}</text>'.format(
                    x=cx + 24, y=yy, c="#34414f", t=esc(txt))); yy += 25

    card(0, "ec2", "EC2 instances (3)", [
        ("swsoc-webserver-grafana-1 · t3a.medium", "b"),
        ("Grafana ×4 + Loki, Telegraf & web svcs", "m"),
        ("hesto-wordpress · t3a.small", "b"),
        ("mediawiki-server · t3a.small", "b"),
    ])
    card(1, "lambda", "Lambda functions (32)", [
        ("7 roles × 4 missions × dev / prod", "n"),
        ("sorting · processing · concating ·", "m"),
        ("artifacts · executor · alert · promtail", "m"),
        ("missions: SDC · PADRE · IMPAX · SWxSOC", "m"),
    ])
    card(2, "registry", "Container images · ECR (33)", [
        ("one private repo per function,", "n"),
        ("per mission, per environment", "m"),
        ("+ promtail · alert · executor repos", "m"),
        ("+ shared public base image", "m"),
    ])
    card(3, "repo", "Source repositories", [
        ("instruments: HERMES · PADRE · IMPAX", "n"),
        ("6 Lambda repos · 2 base images", "m"),
        ("libs: swxsoc · swxsoc_reach · sdc_aws_utils", "m"),
        ("svcs: grafana · telegraf · reach_sync", "m"),
    ])

draw_fleet()

add('</svg>')

svg = "\n".join(OUT)

# --------------------------------------------------------------------------
# Validate + write
# --------------------------------------------------------------------------
try:
    ET.fromstring(svg)
    print("XML OK")
except ET.ParseError as ex:
    print("XML PARSE ERROR:", ex)

# overlap check within lanes
def overlaps():
    bad = []
    for i in range(len(NODES)):
        for j in range(i+1, len(NODES)):
            n, m = NODES[i], NODES[j]
            if n["lane"] != m["lane"]:
                continue
            if (n["x"] < m["x"]+m["w"] and m["x"] < n["x"]+n["w"] and
                n["y"] < m["y"]+m["h"] and m["y"] < n["y"]+n["h"]):
                bad.append((n["id"], m["id"]))
    return bad
ov = overlaps()
print("Node overlaps:", ov if ov else "none")
print("Canvas:", W, "x", H)

here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, "swxsoc_aws_architecture.svg")
with open(path, "w") as f:
    f.write(svg)
print("Wrote", path, len(svg), "bytes")
