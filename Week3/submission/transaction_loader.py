"""
transactional_loader.py
-----------------------
Week 3 Assignment — Q5

Complete the load_batch() function below.

Requirements:
  - Load a list of trip dicts into the trips table
  - All rows must load inside a SINGLE transaction
  - If ANY row fails, roll back the entire batch (no partial commits)
  - Log what went wrong (which row, what error)
  - Return the number of rows loaded (0 on failure)
  - Never silently swallow errors — re-raise after rollback

The connection boilerplate and INSERT SQL are provided.
You write the body of load_batch() and main().

Test your function with:
  1. A clean batch of 5 rows — should commit and return 5
  2. A batch where row 3 has rating=99 — should roll back and return 0
     Verify: the DB row count is unchanged after the failed load.
"""

import psycopg2
import logging
import os

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s"
)
logger = logging.getLogger(__name__)

DB_CONFIG = dict(
    host="localhost",
    port ="5432",
    dbname ="pathao",
    user= "postgres",
    password="thiswillpass"
)

INSERT_SQL = """
    INSERT INTO trips (
        driver_id, rider_id,
        pickup_location_id, dropoff_location_id,
        fare_amount, distance_km, status,
        requested_at, completed_at, rating, payment_method
    ) VALUES (
        %(driver_id)s, %(rider_id)s,
        %(pickup_location_id)s, %(dropoff_location_id)s,
        %(fare_amount)s, %(distance_km)s, %(status)s,
        %(requested_at)s, %(completed_at)s,
        %(rating)s, %(payment_method)s
    )
"""


def load_batch(conn, rows: list) -> int:

    conn.autocommit=False
    row_num = 0

    try:
        with conn.cursor() as cur:
            for row_num, row in enumerate(rows, start=1):
                cur.execute(INSERT_SQL, row)

    except Exception as e:
        conn.rollback()
        logger.error(f"Batch failed at row {row_num}: {e}")
        raise

    else:
        conn.commit()
        logger.info(f"Batch committed successfully: {len(rows)} rows loaded")
        return len(rows)


def get_test_batches():

    base = dict(
        driver_id=1,
        rider_id=1,
        pickup_location_id=1, 
        dropoff_location_id=2,
        fare_amount=250.00, 
        distance_km=8.5,
        status="completed",
        requested_at="2025-01-15 09:00:00",
        completed_at="2025-01-15 09:35:00",
        rating=4.5,
        payment_method="cash"
    )

    good_batch = [{**base, "fare_amount": 100 * (i + 1)} for i in range(5)]

    bad_batch = []
    for i in range(5):
        row = {**base, "fare_amount": 100 * (i + 1)}
        if i == 2:
            row["rating"] = 99  # violates CHECK (rating BETWEEN 1.0 AND 5.0)
        bad_batch.append(row)

    return good_batch, bad_batch


def main():
    conn = psycopg2.connect(**DB_CONFIG)
    good_batch, bad_batch = get_test_batches()

    
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM trips")
        count_before = cur.fetchone()[0]
    logger.info(f"Trips before any load: {count_before:,}")

    # ── Test 1: good batch ────────────────────────────────────────
    logger.info("--- Test 1: loading good batch (expect success) ---")
    try:
        loaded = load_batch(conn, good_batch)
        logger.info(f"Test 1 passed: {loaded} rows loaded")
    except Exception as e:
        logger.error(f"Test 1 failed unexpectedly: {e}")

    # ── Test 2: bad batch ─────────────────────────────────────────
    logger.info("--- Test 2: loading bad batch (expect rollback) ---")
    try:
        loaded = load_batch(conn, bad_batch)
        logger.warning(f"Test 2: loaded {loaded} rows — was rollback triggered?")
    except Exception:
        logger.info("Test 2 passed: exception raised after rollback")

    # ── Verify final count ────────────────────────────────────────
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM trips")
        count_after = cur.fetchone()[0]

    logger.info(f"Trips after both tests: {count_after:,}")
    logger.info(f"Net rows added: {count_after - count_before}")
    # Expected: +5 (good batch committed, bad batch rolled back)

    conn.close()


if __name__ == "__main__":
    main()