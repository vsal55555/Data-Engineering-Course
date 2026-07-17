import logging
import os
from datetime import datetime

def setup_logger():

    os.makedirs("logs", exist_ok=True)

    log_file = (
        f"logs/pipeline_"
        f"{datetime.now():%Y%m%d_%H%M%S}.log"
    )

    logger = logging.getLogger()

    logger.setLevel(logging.INFO)

    logger.handlers.clear()

    formatter = logging.Formatter(
        "%(asctime)s | %(levelname)s | %(name)s | %(message)s"
    )

    file_handler = logging.FileHandler(log_file)

    file_handler.setFormatter(formatter)

    console_handler = logging.StreamHandler()

    console_handler.setFormatter(formatter)

    logger.addHandler(file_handler)

    logger.addHandler(console_handler)

    return logger