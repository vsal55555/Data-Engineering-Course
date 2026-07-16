CREATE TABLE dim_date (
    date_key        INTEGER      PRIMARY KEY,      -- e.g. 20240315
    full_date       DATE         NOT NULL UNIQUE,
    year            SMALLINT     NOT NULL,
    quarter         SMALLINT     NOT NULL CHECK (quarter BETWEEN 1 AND 4),
    month           SMALLINT     NOT NULL CHECK (month BETWEEN 1 AND 12),
    month_name      VARCHAR(10)  NOT NULL,          -- 'January' … 'December'
    week_of_year    SMALLINT     NOT NULL,          -- ISO week 1-53
    day_of_week     SMALLINT     NOT NULL CHECK (day_of_week BETWEEN 0 AND 6), -- 0=Sun
    day_name        VARCHAR(10)  NOT NULL,          -- 'Sunday' … 'Saturday'
    is_weekend      BOOLEAN      NOT NULL
);

-- ─────────────────────────────────────────────────────────────────────────────
-- dim_time
-- Pre-populated with every 15-minute bucket (96 rows).
-- time_key format: HHMM integer rounded down to nearest 15 min.
-- Example: a trip requested at 14:37 gets time_key = 1430.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE dim_time (
    time_key        INTEGER      PRIMARY KEY,   -- HHMM, e.g. 1430 = 2:30 PM
    hour            SMALLINT     NOT NULL CHECK (hour BETWEEN 0 AND 23),
    minute_bucket   SMALLINT     NOT NULL CHECK (minute_bucket IN (0, 15, 30, 45)),
    time_label      VARCHAR(8)   NOT NULL,      -- '14:30'
    time_of_day     VARCHAR(12)  NOT NULL,      -- 'Morning' / 'Afternoon' / 'Evening' / 'Night'
    is_rush_hour    BOOLEAN      NOT NULL       -- TRUE for 7-9am and 5-8pm weekday proxy
);

CREATE TABLE dim_driver (
    driver_key      SERIAL       PRIMARY KEY,
    driver_id       INTEGER      NOT NULL,          -- natural key from OLTP
    name            VARCHAR(100) NOT NULL,
    status          VARCHAR(20)  NOT NULL,          -- active / inactive / suspended
    joined_at       TIMESTAMP,
    tenure_bucket   VARCHAR(20)                 -- '0-6 months' / '6-12 months' / '1-2 years' / '2+ years'
);

CREATE TABLE dim_passenger (
    passenger_key   SERIAL       PRIMARY KEY,
    passenger_id    INTEGER      NOT NULL,
    name            VARCHAR(100) NOT NULL,
    status          VARCHAR(20)  NOT NULL,
    cohort_month    VARCHAR(7),                    -- 'YYYY-MM' — when they first joined
    created_at      TIMESTAMP
);


CREATE TABLE dim_location (
    location_key    SERIAL       PRIMARY KEY,
    location_id     INTEGER      NOT NULL UNIQUE,  -- natural key from OLTP
    city_name       VARCHAR(100) NOT NULL,
    state_province  VARCHAR(100),
    country         VARCHAR(100),
    region          VARCHAR(30),   -- derived: 'Northeast' / 'West' / 'South' / 'Midwest' / 'International'
    latitude        NUMERIC(9,6),
    longitude       NUMERIC(9,6)
);


CREATE TABLE dim_payment_method (
    payment_method_key  SERIAL      PRIMARY KEY,
    payment_method_id   INTEGER     UNIQUE,     -- NULL for the "Unknown" row
    name                VARCHAR(30) NOT NULL,
    type                VARCHAR(20),            -- card / cash / wallet / voucher
    is_active           BOOLEAN
);

CREATE TABLE dim_promo_code (
    promo_code_key  SERIAL       PRIMARY KEY,
    promo_code_id   INTEGER      UNIQUE,    -- NULL = "No Promo" sentinel row
    code            VARCHAR(30),
    discount_type   VARCHAR(10),            -- percent / flat
    discount_value  NUMERIC(8,2),
    is_active       BOOLEAN
);


CREATE TABLE fact_trips (
    trip_key                SERIAL          PRIMARY KEY,
    source_trip_id          INTEGER         NOT NULL UNIQUE,   -- OLTP trips.trip_id — for lineage + ON CONFLICT
 
    -- ── Dimension keys ──────────────────────────────────────────────────────
    date_key                INTEGER         NOT NULL REFERENCES dim_date(date_key),
    driver_key              INTEGER         NOT NULL REFERENCES dim_driver(driver_key),
    passenger_key           INTEGER         NOT NULL REFERENCES dim_passenger(passenger_key),
    pickup_location_key     INTEGER         NOT NULL REFERENCES dim_location(location_key),
    dropoff_location_key    INTEGER         NOT NULL REFERENCES dim_location(location_key),
    payment_method_key      INTEGER         REFERENCES dim_payment_method(payment_method_key),
    promo_code_key          INTEGER         REFERENCES dim_promo_code(promo_code_key),
 
    -- ── Additive measures ───────────────────────────────────────────────────
    base_fare               NUMERIC(10,2),
    tip_amount              NUMERIC(8,2)    NOT NULL DEFAULT 0.00,
    discount_amount         NUMERIC(8,2)    NOT NULL DEFAULT 0.00,
    fare_amount             NUMERIC(10,2),  -- computed: (base_fare × surge) + tip − discount
    distance_km             NUMERIC(6,2),
    duration_minutes        NUMERIC(6,1),   -- NULL for cancelled / no_show
    trip_count              SMALLINT        NOT NULL DEFAULT 1,   -- always 1; useful for COUNT queries
 
    -- ── Semi-additive measures ───────────────────────────────────────────────
    driver_rating           NUMERIC(2,1),   -- passenger → driver (AVG only)
    passenger_rating        NUMERIC(2,1),   -- driver → passenger (AVG only)
 
    -- ── Non-additive measure ─────────────────────────────────────────────────
    surge_multiplier        NUMERIC(4,2),   -- ratio; never SUM, only AVG
 
    -- ── Audit timestamp ──────────────────────────────────────────────────────
    requested_at            TIMESTAMP       NOT NULL
);


--------------------------


--Populate dim_date
-- Generates one row per calendar day from 2023-01-01 to 2026-12-31.
-- Covers the full range of the sample dataset with room for future trips.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO dim_date (
    date_key, full_date, year, quarter, month,
    month_name, week_of_year, day_of_week, day_name, is_weekend
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER                  AS date_key,
    d::DATE                                          AS full_date,
    EXTRACT(YEAR    FROM d)::SMALLINT                AS year,
    EXTRACT(QUARTER FROM d)::SMALLINT                AS quarter,
    EXTRACT(MONTH   FROM d)::SMALLINT                AS month,
    TRIM(TO_CHAR(d, 'Month'))                        AS month_name,   -- trim trailing spaces!
    EXTRACT(WEEK    FROM d)::SMALLINT                AS week_of_year,
    EXTRACT(DOW     FROM d)::SMALLINT                AS day_of_week,  -- 0=Sun, 6=Sat
    TRIM(TO_CHAR(d, 'Day'))                          AS day_name,     -- trim trailing spaces!
    EXTRACT(DOW FROM d) IN (0, 6)                    AS is_weekend
FROM generate_series(
    '2023-01-01'::TIMESTAMP,
    '2026-12-31'::TIMESTAMP,
    '1 day'::INTERVAL
) AS d;


-- ─────────────────────────────────────────────────────────────────────────────
-- Populate dim_time
-- 96 rows — one per 15-minute bucket across 24 hours.
-- ETL maps each trip's requested_at minute to the nearest 15-min bucket.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO dim_time (time_key, hour, minute_bucket, time_label, time_of_day, is_rush_hour)
SELECT
    (h * 100 + m)::INTEGER                               AS time_key,   -- e.g. 1430
    h::SMALLINT                                          AS hour,
    m::SMALLINT                                          AS minute_bucket,
    LPAD(h::TEXT, 2, '0') || ':' || LPAD(m::TEXT, 2, '0') AS time_label, -- '14:30'
    CASE
        WHEN h BETWEEN  6 AND 11 THEN 'Morning'
        WHEN h BETWEEN 12 AND 16 THEN 'Afternoon'
        WHEN h BETWEEN 17 AND 20 THEN 'Evening'
        ELSE                          'Night'
    END                                                  AS time_of_day,
    (h BETWEEN 7 AND 8) OR (h BETWEEN 17 AND 19)        AS is_rush_hour  -- 7–9am, 5–8pm
FROM
    generate_series(0, 23) AS h,
    generate_series(0, 45, 15) AS m
ORDER BY h, m;--------------Repushed to check the changes --------------------------------------
CREATE TABLE dim_date (
    date_key        INTEGER      PRIMARY KEY,      -- e.g. 20240315
    full_date       DATE         NOT NULL UNIQUE,
    year            SMALLINT     NOT NULL,
    quarter         SMALLINT     NOT NULL CHECK (quarter BETWEEN 1 AND 4),
    month           SMALLINT     NOT NULL CHECK (month BETWEEN 1 AND 12),
    month_name      VARCHAR(10)  NOT NULL,          -- 'January' … 'December'
    week_of_year    SMALLINT     NOT NULL,          -- ISO week 1-53
    day_of_week     SMALLINT     NOT NULL CHECK (day_of_week BETWEEN 0 AND 6), -- 0=Sun
    day_name        VARCHAR(10)  NOT NULL,          -- 'Sunday' … 'Saturday'
    is_weekend      BOOLEAN      NOT NULL
);

-- ─────────────────────────────────────────────────────────────────────────────
-- dim_time
-- Pre-populated with every 15-minute bucket (96 rows).
-- time_key format: HHMM integer rounded down to nearest 15 min.
-- Example: a trip requested at 14:37 gets time_key = 1430.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE dim_time (
    time_key        INTEGER      PRIMARY KEY,   -- HHMM, e.g. 1430 = 2:30 PM
    hour            SMALLINT     NOT NULL CHECK (hour BETWEEN 0 AND 23),
    minute_bucket   SMALLINT     NOT NULL CHECK (minute_bucket IN (0, 15, 30, 45)),
    time_label      VARCHAR(8)   NOT NULL,      -- '14:30'
    time_of_day     VARCHAR(12)  NOT NULL,      -- 'Morning' / 'Afternoon' / 'Evening' / 'Night'
    is_rush_hour    BOOLEAN      NOT NULL       -- TRUE for 7-9am and 5-8pm weekday proxy
);

CREATE TABLE dim_driver (
    driver_key      SERIAL       PRIMARY KEY,
    driver_id       INTEGER      NOT NULL,          -- natural key from OLTP
    name            VARCHAR(100) NOT NULL,
    status          VARCHAR(20)  NOT NULL,          -- active / inactive / suspended
    joined_at       TIMESTAMP,
    tenure_bucket   VARCHAR(20)                 -- '0-6 months' / '6-12 months' / '1-2 years' / '2+ years'
);

CREATE TABLE dim_passenger (
    passenger_key   SERIAL       PRIMARY KEY,
    passenger_id    INTEGER      NOT NULL,
    name            VARCHAR(100) NOT NULL,
    status          VARCHAR(20)  NOT NULL,
    cohort_month    VARCHAR(7),                    -- 'YYYY-MM' — when they first joined
    created_at      TIMESTAMP
);


CREATE TABLE dim_location (
    location_key    SERIAL       PRIMARY KEY,
    location_id     INTEGER      NOT NULL UNIQUE,  -- natural key from OLTP
    city_name       VARCHAR(100) NOT NULL,
    state_province  VARCHAR(100),
    country         VARCHAR(100),
    region          VARCHAR(30),   -- derived: 'Northeast' / 'West' / 'South' / 'Midwest' / 'International'
    latitude        NUMERIC(9,6),
    longitude       NUMERIC(9,6)
);


CREATE TABLE dim_payment_method (
    payment_method_key  SERIAL      PRIMARY KEY,
    payment_method_id   INTEGER     UNIQUE,     -- NULL for the "Unknown" row
    name                VARCHAR(30) NOT NULL,
    type                VARCHAR(20),            -- card / cash / wallet / voucher
    is_active           BOOLEAN
);

CREATE TABLE dim_promo_code (
    promo_code_key  SERIAL       PRIMARY KEY,
    promo_code_id   INTEGER      UNIQUE,    -- NULL = "No Promo" sentinel row
    code            VARCHAR(30),
    discount_type   VARCHAR(10),            -- percent / flat
    discount_value  NUMERIC(8,2),
    is_active       BOOLEAN
);


CREATE TABLE fact_trips (
    trip_key                SERIAL          PRIMARY KEY,
    source_trip_id          INTEGER         NOT NULL UNIQUE,   -- OLTP trips.trip_id — for lineage + ON CONFLICT
 
    -- ── Dimension keys ──────────────────────────────────────────────────────
    date_key                INTEGER         NOT NULL REFERENCES dim_date(date_key),
    driver_key              INTEGER         NOT NULL REFERENCES dim_driver(driver_key),
    passenger_key           INTEGER         NOT NULL REFERENCES dim_passenger(passenger_key),
    pickup_location_key     INTEGER         NOT NULL REFERENCES dim_location(location_key),
    dropoff_location_key    INTEGER         NOT NULL REFERENCES dim_location(location_key),
    payment_method_key      INTEGER         REFERENCES dim_payment_method(payment_method_key),
    promo_code_key          INTEGER         REFERENCES dim_promo_code(promo_code_key),
 
    -- ── Additive measures ───────────────────────────────────────────────────
    base_fare               NUMERIC(10,2),
    tip_amount              NUMERIC(8,2)    NOT NULL DEFAULT 0.00,
    discount_amount         NUMERIC(8,2)    NOT NULL DEFAULT 0.00,
    fare_amount             NUMERIC(10,2),  -- computed: (base_fare × surge) + tip − discount
    distance_km             NUMERIC(6,2),
    duration_minutes        NUMERIC(6,1),   -- NULL for cancelled / no_show
    trip_count              SMALLINT        NOT NULL DEFAULT 1,   -- always 1; useful for COUNT queries
 
    -- ── Semi-additive measures ───────────────────────────────────────────────
    driver_rating           NUMERIC(2,1),   -- passenger → driver (AVG only)
    passenger_rating        NUMERIC(2,1),   -- driver → passenger (AVG only)
 
    -- ── Non-additive measure ─────────────────────────────────────────────────
    surge_multiplier        NUMERIC(4,2),   -- ratio; never SUM, only AVG
 
    -- ── Audit timestamp ──────────────────────────────────────────────────────
    requested_at            TIMESTAMP       NOT NULL
);


--------------------------


--Populate dim_date
-- Generates one row per calendar day from 2023-01-01 to 2026-12-31.
-- Covers the full range of the sample dataset with room for future trips.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO dim_date (
    date_key, full_date, year, quarter, month,
    month_name, week_of_year, day_of_week, day_name, is_weekend
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER                  AS date_key,
    d::DATE                                          AS full_date,
    EXTRACT(YEAR    FROM d)::SMALLINT                AS year,
    EXTRACT(QUARTER FROM d)::SMALLINT                AS quarter,
    EXTRACT(MONTH   FROM d)::SMALLINT                AS month,
    TRIM(TO_CHAR(d, 'Month'))                        AS month_name,   -- trim trailing spaces!
    EXTRACT(WEEK    FROM d)::SMALLINT                AS week_of_year,
    EXTRACT(DOW     FROM d)::SMALLINT                AS day_of_week,  -- 0=Sun, 6=Sat
    TRIM(TO_CHAR(d, 'Day'))                          AS day_name,     -- trim trailing spaces!
    EXTRACT(DOW FROM d) IN (0, 6)                    AS is_weekend
FROM generate_series(
    '2023-01-01'::TIMESTAMP,
    '2026-12-31'::TIMESTAMP,
    '1 day'::INTERVAL
) AS d;


-- ─────────────────────────────────────────────────────────────────────────────
-- Populate dim_time
-- 96 rows — one per 15-minute bucket across 24 hours.
-- ETL maps each trip's requested_at minute to the nearest 15-min bucket.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO dim_time (time_key, hour, minute_bucket, time_label, time_of_day, is_rush_hour)
SELECT
    (h * 100 + m)::INTEGER                               AS time_key,   -- e.g. 1430
    h::SMALLINT                                          AS hour,
    m::SMALLINT                                          AS minute_bucket,
    LPAD(h::TEXT, 2, '0') || ':' || LPAD(m::TEXT, 2, '0') AS time_label, -- '14:30'
    CASE
        WHEN h BETWEEN  6 AND 11 THEN 'Morning'
        WHEN h BETWEEN 12 AND 16 THEN 'Afternoon'
        WHEN h BETWEEN 17 AND 20 THEN 'Evening'
        ELSE                          'Night'
    END                                                  AS time_of_day,
    (h BETWEEN 7 AND 8) OR (h BETWEEN 17 AND 19)        AS is_rush_hour  -- 7–9am, 5–8pm
FROM
    generate_series(0, 23) AS h,
    generate_series(0, 45, 15) AS m
ORDER BY h, m;

------------------------------------------------Assignment starts here---------------------------------------------------------
----------------------------------------------Questions.1 On warehouse.sql — add the vehicle dimension------------------------------------
--Answer
CREATE TABLE dim_vehicle (
    vehicle_key     SERIAL PRIMARY KEY, --Surrogate keys: warehouse uses its own SERIAL PKs i.e warehouse-generated identifier
    vehicle_id      INTEGER NOT NULL, -- natural key from OLTP
    plate_number    VARCHAR(50),
    make            VARCHAR(100),
    model           VARCHAR(100),
    year            INTEGER,
    color           VARCHAR(50),
    category        VARCHAR(50),
    is_active       BOOLEAN
);

--is vehicle_id always present on a trip in the OLTP schema? Is a time always known?
--Answer:
ALTER TABLE fact_trips
ADD COLUMN vehicle_key INTEGER NOT NULL,
ADD COLUMN time_key INTEGER NOT NULL;

ALTER TABLE fact_trips
ADD CONSTRAINT fk_fact_vehicle
FOREIGN KEY (vehicle_key)
REFERENCES dim_vehicle(vehicle_key);
--Because every trip in the OLTP system is associated with a vehicle through vehicle_id, 
--so every fact row should have a corresponding vehicle dimension record.

ALTER TABLE fact_trips
ADD CONSTRAINT fk_fact_time
FOREIGN KEY (time_key)
REFERENCES dim_time(time_key);
--Every trip has a requested_at timestamp, so a corresponding time/date dimension row always exists.
--Therefore time_key should not be NULL.

---------------------------Question 3:  Write a warehouse query that returns total revenue grouped by pickup city and month.-------------------
--Then write the equivalent query against the OLTP schema (trips, locations, etc.) directly.
--Answer: how many table joins does each version need? Which one needed fewer, and why?

SELECT
    l.city_name,
    d.year,
    d.month,
    SUM(f.fare_amount) AS total_revenue
FROM fact_trips f
JOIN dim_location l
    ON f.pickup_location_key = l.location_key
JOIN dim_date d
    ON f.date_key = d.date_key
GROUP BY
    l.city_name,
    d.year,
    d.month
ORDER BY
    l.city_name,
    d.year,
    d.month;

--Warehouse Query needs 2 joins.
--fact_trips → dim_location
--fact_trips → dim_date

--OLTP Query needs 1 join. 
--trips → locations
--Conclusion: OLTP query needed fewer joins.

--Why is Warehouse Still Better?
--Because:
--Revenue was already calculated during ETL.
--Date attributes (year/month) already exist in dimensions.
--Business Analyst users write fewer and simpler reporting queries.
--Large analytical workloads run faster because facts and dimensions are designed for reporting.

----------------------------------------------------Question 4. Payment method revenue--------------------------------------------------
--Write a warehouse query for total revenue per payment method.
SELECT
    pm.name AS payment_method,
    SUM(f.fare_amount) AS total_revenue
FROM fact_trips f
JOIN dim_payment_method pm
    ON f.payment_method_key = pm.payment_method_key
GROUP BY
    pm.name
ORDER BY
    total_revenue DESC;

--Extend it (or write a second query) for average fare per trip, per payment method, per month
SELECT
    pm.name AS payment_method,
    d.year,
    d.month,
    ROUND(AVG(f.fare_amount), 2) AS avg_fare_per_trip
FROM fact_trips f
JOIN dim_payment_method pm
    ON f.payment_method_key = pm.payment_method_key
JOIN dim_date d
    ON f.date_key = d.date_key
GROUP BY
    pm.name,
    d.year,
    d.month
ORDER BY
    d.year,
    d.month,
    pm.name;

--------------------------------------------Question 5. Busiest hour of day----------------------------------------------
--Write a warehouse query that returns trip count per hour of day (0–23), 
--along with each hour's percentage of all trips — computed with a window function (not a second query for the grand total).

SELECT
    t.hour,
    COUNT(*) AS trip_count,

    ROUND(
        COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER (),
        2
    ) AS pct_of_all_trips

FROM fact_trips f
JOIN dim_time t
    ON f.time_key = t.time_key
GROUP BY
    t.hour
ORDER BY
    trip_count DESC;

--------------------------------------------Question 7. Stretch: incremental load (watermark pattern)-------------------------------
--Modify etl.py so the fact load only extracts trips newer than the MAX(requested_at) already present in fact_trips?
--Answer: Created an new function as get_watermark() and pass watermark to extract trips function based on watermark is null or new.

--Where should that watermark be read from?
--Answer: from the warehouse fact table because warehouse knows what has already been loaded.

--and what happens the very first time the ETL runs against an empty warehouse?
--Answer: On the first run, fact_trips is empty, so MAX(requested_at) returns NULL. The ETL should treat a NULL watermark as an initial load and extract all trips from the source system.
