import os
from dotenv import load_dotenv

load_dotenv()

# -----------------------------------
# Validate Required Environment Vars
# -----------------------------------

required_vars = [
    "SRC_DB_HOST",
    "SRC_DB_PORT",
    "SRC_DB_NAME",
    "SRC_DB_USER",
    "SRC_DB_PASSWORD",
    "DEST_DB_HOST",
    "DEST_DB_PORT",
    "DEST_DB_NAME",
    "DEST_DB_USER",
    "DEST_DB_PASSWORD",
]

missing = [var for var in required_vars if not os.getenv(var)]

if missing:
    raise EnvironmentError(
        "Missing required environment variables: "
        + ", ".join(missing)
    )

# -----------------------------------
# Source Database Config
# -----------------------------------

SOURCE_DB_CONFIG = {
    "host": os.getenv("SRC_DB_HOST"),
    "port": int(os.getenv("SRC_DB_PORT")),
    "dbname": os.getenv("SRC_DB_NAME"),
    "user": os.getenv("SRC_DB_USER"),
    "password": os.getenv("SRC_DB_PASSWORD"),
}

# -----------------------------------
# Destination Database Config
# -----------------------------------

DEST_DB_CONFIG = {
    "host": os.getenv("DEST_DB_HOST"),
    "port": int(os.getenv("DEST_DB_PORT")),
    "dbname": os.getenv("DEST_DB_NAME"),
    "user": os.getenv("DEST_DB_USER"),
    "password": os.getenv("DEST_DB_PASSWORD"),
}