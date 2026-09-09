#!/usr/bin/env python3
"""Aggregate the ten-task pilot registry without inventing a single number.

Reads docs/testing/pilot-10-tasks.csv, validates every row against the
protocol in docs/testing/workflow.md and prints the priority metrics as JSON.
A row only counts as measured when every measurement is present; an accepted
task without evidence, an unknown cost or an empty human-minutes cell is
reported as such and never treated as zero. Exit 1 on an invalid registry.
"""
import argparse
import csv
import json
import pathlib
import sys

COLUMNS = ["slot", "status", "project", "task", "acceptance_criterion", "source_snapshot",
           "context_variant", "model_versions", "evidence_path", "attempts", "total_cost_eur",
           "human_minutes", "elapsed_minutes", "accepted", "regressions", "notes"]
STATUSES = {"pending", "in_progress", "observed_incomplete", "measured"}
MEASURED_FIELDS = ["project", "task", "acceptance_criterion", "source_snapshot", "context_variant",
                   "model_versions", "evidence_path", "attempts", "total_cost_eur", "human_minutes",
                   "elapsed_minutes", "accepted", "regressions"]
ACCEPTED_VALUES = {"yes", "no", "abandoned"}


class RegistryError(Exception):
    pass


def number(value, field, slot, minimum=0.0):
    try:
        parsed = float(value)
    except ValueError:
        raise RegistryError(f"slot {slot}: {field} is not a number: {value!r}") from None
    if parsed != parsed or parsed < minimum:
        raise RegistryError(f"slot {slot}: {field} must be >= {minimum}: {value!r}")
    return parsed


def load(path):
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != COLUMNS:
            raise RegistryError("unexpected columns: " + ",".join(reader.fieldnames or []))
        rows = list(reader)
    if len(rows) != 10:
        raise RegistryError(f"the registry holds ten slots, found {len(rows)}")
    seen = set()
    for row in rows:
        slot = row["slot"]
        if not slot.isdigit() or slot in seen or not 1 <= int(slot) <= 10:
            raise RegistryError(f"invalid or duplicated slot {slot!r}")
        seen.add(slot)
        if row["status"] not in STATUSES:
            raise RegistryError(f"slot {slot}: unknown status {row['status']!r}")
        if row["status"] == "measured":
            missing = [field for field in MEASURED_FIELDS if not row[field].strip()]
            if missing:
                raise RegistryError(f"slot {slot}: measured without " + ", ".join(missing))
            if row["accepted"] not in ACCEPTED_VALUES:
                raise RegistryError(f"slot {slot}: accepted must be one of {sorted(ACCEPTED_VALUES)}")
            number(row["attempts"], "attempts", slot, 1)
            for field in ("total_cost_eur", "human_minutes", "elapsed_minutes", "regressions"):
                number(row[field], field, slot)
        elif row["status"] == "pending" and any(row[field].strip() for field in MEASURED_FIELDS):
            raise RegistryError(f"slot {slot}: pending rows carry no measurements")
    return rows


def metrics(rows):
    measured = [row for row in rows if row["status"] == "measured"]
    accepted = [row for row in measured if row["accepted"] == "yes"]
    attempted = len(measured)
    cost = sum(float(row["total_cost_eur"]) for row in measured)
    human = sum(float(row["human_minutes"]) for row in measured)
    regressions = sum(int(float(row["regressions"])) for row in measured)
    variants = sorted({row["context_variant"] for row in measured})
    return {
        "slots": 10,
        "measured": attempted,
        "pending": sum(row["status"] == "pending" for row in rows),
        "observed_incomplete": sum(row["status"] == "observed_incomplete" for row in rows),
        "accepted": len(accepted),
        "acceptance_rate": (len(accepted) / attempted) if attempted else None,
        "cost_eur_per_accepted": (cost / len(accepted)) if accepted else None,
        "human_minutes_per_accepted": (human / len(accepted)) if accepted else None,
        "regressions_after_acceptance": regressions,
        "context_variants": variants,
        "instrumentation_verified": attempted >= 10,
        "claim": ("ten measured tasks: instrumentation verified, compare variants" if attempted >= 10
                  else f"{attempted}/10 measured: no productivity claim can be made"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("registry", nargs="?", default="docs/testing/pilot-10-tasks.csv", type=pathlib.Path)
    args = parser.parse_args()
    try:
        report = metrics(load(args.registry))
    except (RegistryError, OSError) as error:
        print(json.dumps({"status": "invalid", "error": str(error)}))
        return 1
    print(json.dumps({"status": "ok", **report}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
