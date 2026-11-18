"""
SQL-Based Enterprise Data Integration Solution
----------------------------------------------
A small ETL pipeline that integrates data from several source systems
(CRM customers, ERP customers, product master, ERP orders) into a SQLite
data warehouse. All business logic lives in SQL files; this script only
orchestrates the steps:

    1. Create schema          (sql/schema.sql)
    2. Load raw CSVs to staging tables
    3. Cleanse + integrate    (sql/transform.sql)  -> dim_customer, dim_product, fact_sales
    4. Data quality checks    (sql/quality_checks.sql)
    5. Write the run log and print business reports (sql/reports.sql)

Usage:
    python etl.py
    python etl.py --db warehouse.db --data data --sql sql
"""

import argparse
import csv
import re
import sqlite3
from pathlib import Path

BASE = Path(__file__).resolve().parent

# staging table -> source file
STAGING_FILES = {
    "stg_crm_customers": "crm_customers.csv",
    "stg_erp_customers": "erp_customers.csv",
    "stg_products": "products.csv",
    "stg_orders": "erp_orders.csv",
}


def read_sql(sql_dir, name):
    return (Path(sql_dir) / name).read_text(encoding="utf-8")


# --------------------------------------------------------------------------
# Extract / load to staging
# --------------------------------------------------------------------------
def load_staging(conn, data_dir):
    """Reload every staging table from its CSV. Values are kept as raw text;
    only empty cells become NULL. Cleansing is done later, in SQL."""
    counts = {}
    for table, filename in STAGING_FILES.items():
        expected = [row[1] for row in conn.execute(f"PRAGMA table_info({table})")]
        with open(Path(data_dir) / filename, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if reader.fieldnames != expected:
                raise ValueError(f"{filename}: columns {reader.fieldnames} do not match {expected}")
            rows = [[(r[c] if r[c] and r[c].strip() else None) for c in expected] for r in reader]

        conn.execute(f"DELETE FROM {table}")
        placeholders = ",".join("?" * len(expected))
        conn.executemany(f"INSERT INTO {table} ({','.join(expected)}) VALUES ({placeholders})", rows)
        counts[table] = len(rows)
    conn.commit()
    return counts


# --------------------------------------------------------------------------
# Pipeline
# --------------------------------------------------------------------------
def run_pipeline(conn, data_dir=BASE / "data", sql_dir=BASE / "sql"):
    """Run the full ETL and return a summary dict."""
    conn.executescript(read_sql(sql_dir, "schema.sql"))
    staged = load_staging(conn, data_dir)
    conn.executescript(read_sql(sql_dir, "transform.sql"))

    checks = conn.execute(read_sql(sql_dir, "quality_checks.sql")).fetchall()
    failed = [(name, n) for name, n in checks if n > 0]

    loaded = conn.execute("SELECT COUNT(*) FROM fact_sales").fetchone()[0]
    rejected = conn.execute(
        "SELECT COUNT(*) FROM rejected_records WHERE source_table = 'stg_orders'"
    ).fetchone()[0]
    status = "SUCCESS" if not failed else "COMPLETED_WITH_ERRORS"

    conn.execute(
        "INSERT INTO etl_run_log (staged_orders, loaded_orders, rejected_orders, checks_failed, status) "
        "VALUES (?,?,?,?,?)",
        (staged["stg_orders"], loaded, rejected, len(failed), status),
    )
    conn.commit()
    return {"staged": staged, "loaded_orders": loaded, "rejected_orders": rejected,
            "checks": checks, "failed_checks": failed, "status": status}


def load_named_queries(path):
    """Split a SQL file into {name: query} using '-- name: xyz' marker lines."""
    parts = re.split(r"^-- name:\s*(\S+)\s*$", Path(path).read_text(encoding="utf-8"), flags=re.M)
    return {parts[i]: parts[i + 1].strip() for i in range(1, len(parts), 2)}


def run_reports(conn, sql_dir=BASE / "sql"):
    out = {}
    for name, query in load_named_queries(Path(sql_dir) / "reports.sql").items():
        cur = conn.execute(query)
        out[name] = ([d[0] for d in cur.description], cur.fetchall())
    return out


# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
def format_table(columns, rows):
    cells = [[str(v) for v in r] for r in rows]
    widths = [max(len(c), *(len(r[i]) for r in cells)) if cells else len(c)
              for i, c in enumerate(columns)]
    line = "  ".join(c.ljust(w) for c, w in zip(columns, widths))
    body = ["  ".join(v.ljust(w) for v, w in zip(r, widths)) for r in cells]
    return "\n".join(["  " + line, "  " + "-" * len(line)] + ["  " + b for b in body])


def export_rejected(conn, path):
    cur = conn.execute("SELECT source_table, record_key, reason, raw_data FROM rejected_records ORDER BY id")
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([d[0] for d in cur.description])
        w.writerows(cur.fetchall())


def main():
    p = argparse.ArgumentParser(description="SQL-based enterprise data integration (ETL)")
    p.add_argument("--db", default="warehouse.db", help="SQLite warehouse file")
    p.add_argument("--data", default=str(BASE / "data"), help="folder with source CSV files")
    p.add_argument("--sql", default=str(BASE / "sql"), help="folder with SQL scripts")
    p.add_argument("--rejected", default="rejected_records.csv", help="export file for rejected rows")
    args = p.parse_args()

    conn = sqlite3.connect(args.db)
    result = run_pipeline(conn, args.data, args.sql)

    print("=== Staged rows ===")
    for table, n in result["staged"].items():
        print(f"  {table:<20} {n}")
    print(f"\n=== Orders: {result['loaded_orders']} loaded, {result['rejected_orders']} rejected ===")

    print("\n=== Data quality checks ===")
    for name, failures in result["checks"]:
        print(f"  [{'PASS' if failures == 0 else 'FAIL'}] {name}" + (f" ({failures})" if failures else ""))

    for name, (cols, rows) in run_reports(conn, args.sql).items():
        print(f"\n=== Report: {name} ===")
        print(format_table(cols, rows))

    export_rejected(conn, args.rejected)
    conn.close()
    print(f"\nETL status: {result['status']}. Warehouse: {args.db}; rejected rows: {args.rejected}")


if __name__ == "__main__":
    main()
