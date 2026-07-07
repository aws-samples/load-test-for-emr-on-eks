#!/usr/bin/env python3
"""Normalize a Grafana dashboard JSON for sidecar auto-import.

The dashboards under grafana/dashboard-template/ were exported from a Grafana UI,
so most carry export-only cruft that breaks a headless import:

  * ``__inputs`` / ``__requires`` / ``__elements`` metadata, and
  * datasource placeholders like ``${DS_PROMETHEUS}`` woven through every panel
    target (both as declared inputs and inline). Loaded as-is, every panel shows
    "Datasource ${DS_PROMETHEUS} not found".

This rewrites a dashboard so the kube-prometheus-stack Grafana sidecar can load
it against the in-cluster Prometheus:

  * strips the export metadata and nulls ``id`` (Grafana assigns its own),
  * rewrites every datasource placeholder to a single ``${datasource}`` template
    variable -- exactly what Grafana does when you bind a datasource on manual
    import, and
  * injects that ``datasource`` template variable (type=datasource,
    query=prometheus) when one is needed, so it defaults to the stack's default
    Prometheus with no user interaction.

Usage: transform-dashboard.py < in.json > out.json
"""
from __future__ import annotations

import json
import re
import sys

# Datasource placeholders take two shapes across these exports:
#   ${DS_PROMETHEUS}, ${DS_PROMETHEUS-CLUSTER-10}  (the conventional DS_ prefix)
#   ${PrometheusDataSource}                        (a custom input name)
# Match both so no panel is left pointing at a dangling variable.
_DS_PLACEHOLDER = re.compile(
    r"\$\{(DS_[A-Za-z0-9_\-]+|[A-Za-z0-9_\-]*[Dd]ata[Ss]ource[A-Za-z0-9_\-]*)\}"
)

_DATASOURCE_VAR = {
    "name": "datasource",
    "label": "Data source",
    "type": "datasource",
    "query": "prometheus",
    "current": {},
    "hide": 0,
    "refresh": 1,
    "regex": "",
    "includeAll": False,
    "multi": False,
}


def transform(doc: dict) -> dict:
    # Some exports wrap the dashboard as {"dashboard": {...}, "meta": ...}; the
    # sidecar wants the bare dashboard model, so unwrap it.
    if isinstance(doc, dict) and "panels" in doc.get("dashboard", {}):
        doc = doc["dashboard"]

    for key in ("__inputs", "__requires", "__elements"):
        doc.pop(key, None)
    doc["id"] = None  # let Grafana assign an id instead of colliding on import

    # A dashboard may ALREADY define its own datasource template variable (e.g.
    # eks-control-plane.json has one named DS_PROMETHEUS). Those ${name} refs
    # resolve on their own, so leave them untouched -- rewriting them would
    # orphan the existing variable and leave two datasource dropdowns. Only
    # placeholders with no backing variable (the __inputs-style import
    # placeholders) need rewriting to a single injected ``datasource`` variable.
    existing_vars = {
        v.get("name")
        for v in doc.get("templating", {}).get("list", [])
        if v.get("type") == "datasource"
    }

    def _rewrite(m: re.Match) -> str:
        return m.group(0) if m.group(1) in existing_vars else "${datasource}"

    text = json.dumps(doc)
    unbound = [m.group(1) for m in _DS_PLACEHOLDER.finditer(text)
               if m.group(1) not in existing_vars]
    text = _DS_PLACEHOLDER.sub(_rewrite, text)
    doc = json.loads(text)

    if unbound:
        tmpl = doc.setdefault("templating", {}).setdefault("list", [])
        if not any(v.get("name") == "datasource" for v in tmpl):
            tmpl.insert(0, dict(_DATASOURCE_VAR))
    return doc


def main() -> int:
    try:
        doc = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"invalid dashboard JSON: {e}\n")
        return 1
    json.dump(transform(doc), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
