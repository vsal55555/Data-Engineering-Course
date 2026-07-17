
import psycopg2
from psycopg2.extras import RealDictCursor
import logging
import os
import time
import argparse
from datetime import datetime
from quality  import run_quality_checks
from transform import transform
from logger_config import setup_logger
from quality import DataQualityError

from load import (
    load_dim_driver,
    load_dim_vehicle,
    load_dim_passenger,
    load_dim_location,
    load_dim_payment_method,
    load_dim_promo_code,
    load_fact_trips
)

from extract import (
    extract,
    extract_driver,
    extract_vehicle,
    extract_passenger,
    extract_location,
    extract_payment_method,
    extract_promo_code,
    extract_trips_full,
    extract_trips_incremental,
    extract_lookup_dim,
    get_watermark
)

from config import (SOURCE_DB_CONFIG, DEST_DB_CONFIG)

def parse_args():
    parser = argparse.ArgumentParser(description="Rides ETL pipeline")
    parser.add_argument(
        "--full-reload",
        action="store_true",
        help="Truncate warehouse and reload all data (default: incremental)"
    )
    return parser.parse_args()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s [%(filename)s:%(lineno)d] %(message)s"
)
logger = logging.getLogger(__name__)



def main():
    
    logger = setup_logger()
    logger.info("Pipeline Started")
    pipeline_start = time.time()
    args = parse_args()
    mode = 'FULL' if args.full_reload else 'INCREMENTAL'
    """
    Extract all dimension data from the source DB and load them into the target DB.
    """

    src_conn = psycopg2.connect(**SOURCE_DB_CONFIG)
    dst_conn = psycopg2.connect(**DEST_DB_CONFIG)

    try:
        time0 = time.time()
        driver_data = extract_driver(src_conn)
        load_dim_driver(dst_conn, driver_data)

        vehicle_data = extract_vehicle(src_conn)
        load_dim_vehicle(dst_conn, vehicle_data)

        passenger_data = extract_passenger(src_conn)
        load_dim_passenger(dst_conn, passenger_data)

        location_data = extract_location(src_conn)
        load_dim_location(dst_conn, location_data)

        payment_method_data = extract_payment_method(src_conn)
        load_dim_payment_method(dst_conn, payment_method_data)

        promo_code_data = extract_promo_code(src_conn)
        load_dim_promo_code(dst_conn, promo_code_data)
        logger.info(f"Dimention table load completed on {time.time() - time0:.2f}s")

        time0 = time.time()
        lookups = extract_lookup_dim(dst_conn)
        logger.info(f"Lookup table extraction completed on {time.time() - time0:.2f}s")

        #create a function to Read   Watermark
        #When watermark = None,i.e Null watermark. ETL should interpret None as Initial load and load ALL trips.
        time0 = time.time()
        if mode == 'INCREMENTAL':
            watermark = get_watermark(dst_conn)
            rows = extract_trips_incremental(src_conn,{"watermark":watermark})
        else:
            rows = extract_trips_full(src_conn)
        logger.info(f"Trip extraction  completed on {time.time() - time0:.2f}s")

        #rows = extract_trips(src_conn)           Removed since it extracts ALL trips every run.
        time0 = time.time()
        fact_rows = transform(rows, lookups)
        logger.info(f"Transformation completed on {time.time() - time0:.2f}s")

        time0 = time.time()
        run_quality_checks(fact_rows)
        logger.info(f"Quality Check completed on {time.time() - time0:.2f}s")

        time0 = time.time()
        load_fact_trips(dst_conn, fact_rows)
        logger.info(f"Trip table load completed on {time.time() - time0:.2f}s")

    except DataQualityError as e:
        logger.error(f"QUALITY CHECK FAILED: {str(e)}")
        logger.error(f"Pipeline Aborted")
        return

    finally:
        src_conn.close()
        dst_conn.close()

        logger.info(f"Pipeline complete in "f"{time.time() - pipeline_start:.2f}s")

if __name__ == "__main__":
        main()

