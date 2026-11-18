import sqlite3
import unittest

import etl


class EtlTests(unittest.TestCase):
    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.result = etl.run_pipeline(self.conn)

    def tearDown(self):
        self.conn.close()

    def one(self, sql, *args):
        return self.conn.execute(sql, args).fetchone()[0]

    # --- integration of customers ------------------------------------------------
    def test_customers_are_merged_on_email(self):
        self.assertEqual(self.one("SELECT COUNT(*) FROM dim_customer"), 6)
        sources = dict(self.conn.execute(
            "SELECT email, source_system FROM dim_customer").fetchall())
        self.assertEqual(sources["asha.verma@example.com"], "BOTH")
        self.assertEqual(sources["li.wei@example.com"], "CRM")
        self.assertEqual(sources["priya.nair@example.com"], "ERP")

    def test_crm_duplicates_are_collapsed(self):
        self.assertEqual(self.one(
            "SELECT crm_customer_id FROM dim_customer WHERE email = 'asha.verma@example.com'"), "C001")

    def test_email_and_country_are_cleansed(self):
        country = self.one("SELECT country FROM dim_customer WHERE email = 'john.carter@example.com'")
        self.assertEqual(country, "US")   # 'USA' in CRM, 'United States' in ERP
        self.assertEqual(self.one(
            "SELECT country FROM dim_customer WHERE email = 'tom.baker@example.com'"), "GB")

    def test_product_cleansing(self):
        row = self.conn.execute(
            "SELECT sku, category FROM dim_product WHERE sku = 'P-500'").fetchone()
        self.assertEqual(row, ("P-500", "Uncategorized"))

    # --- order validation ----------------------------------------------------------
    def test_orders_loaded_and_rejected(self):
        self.assertEqual(self.one("SELECT COUNT(*) FROM fact_sales"), 7)
        reasons = dict(self.conn.execute("SELECT record_key, reason FROM rejected_records").fetchall())
        self.assertEqual(reasons, {
            "O1001": "Duplicate order",
            "O1007": "Unknown customer",
            "O1008": "Unknown product",
            "O1009": "Invalid quantity",
            "O1010": "Invalid order date",
            "O1012": "Invalid unit price",
        })

    def test_fact_measures(self):
        revenue, cost = self.conn.execute(
            "SELECT revenue, cost FROM fact_sales WHERE order_id = 'O1003'").fetchone()
        self.assertEqual((revenue, cost), (520.0, 360.0))

    # --- quality checks, logging, reports -------------------------------------------------
    def test_quality_checks_pass(self):
        self.assertEqual(self.result["failed_checks"], [])
        self.assertEqual(self.result["status"], "SUCCESS")

    def test_pipeline_is_repeatable(self):
        etl.run_pipeline(self.conn)
        self.assertEqual(self.one("SELECT COUNT(*) FROM fact_sales"), 7)
        self.assertEqual(self.one("SELECT COUNT(*) FROM dim_customer"), 6)
        self.assertEqual(self.one("SELECT COUNT(*) FROM rejected_records"), 6)
        self.assertEqual(self.one("SELECT COUNT(*) FROM etl_run_log"), 2)

    def test_report_excludes_cancelled_orders(self):
        cols, rows = etl.run_reports(self.conn)["revenue_by_country"]
        revenue = {r[0]: r[2] for r in rows}
        self.assertEqual(revenue["IN"], 3780.0)   # O1006 (cancelled) is excluded


if __name__ == "__main__":
    unittest.main()
