-- week3_reliability.sql
-- Week 3 Assignment
-- Submit TWO files:
--   1. week3_reliability.sql  (this file — SQL tasks)
--   2. transactional_loader.py (Python task — Q5)
--
-- All SQL runs against the normalized schema from Week 2
-- (drivers, riders, locations, trips)

-- ─────────────────────────────────────────────────────────────────
-- Q1: Add indexes to the trips table
--
-- Before adding ANY index, run EXPLAIN ANALYZE on each query below
-- and record the execution time in a comment.
-- Then add your indexes and run EXPLAIN ANALYZE again.
-- The comparison IS the answer — not just the CREATE INDEX statement.
-- ─────────────────────────────────────────────────────────────────

-- Baseline queries — run EXPLAIN ANALYZE on each BEFORE indexing:

-- Query A: filter by driver
EXPLAIN ANALYZE;
SELECT * FROM trips; WHERE driver_id = 3;


-- Query B: filter by status
EXPLAIN ANALYZE
SELECT * FROM trips WHERE status = 'cancelled';


-- Query C: filter by driver AND status (common in the pipeline)
EXPLAIN ANALYZE
SELECT * FROM trips
WHERE driver_id = 3 AND status = 'completed';


-- YOUR INDEXES HERE:
CREATE INDEX trips_index_driver_id
ON trips(driver_id);

CREATE INDEX trips_index_status
ON trips(status);


-- (add indexes, then re-run the EXPLAIN ANALYZE queries above)

-- Query A before: Seq Scan, execution time = 2.273 ms
-- Query A after:  Index Scan using trips_index_driver_id, execution time = 0.505 ms

-- Query B before: Seq Scan, execution time = 6.873 ms
-- Query B after:  Index Scan using trips_index_status, execution time = 2.057 ms

-- Query C before: Seq Scan, execution time = 4.423 ms
-- Query C after:  Index Scan using trips_index_driver_id and trips_index_status, execution time = 0.785 ms


-- ─────────────────────────────────────────────────────────────────
-- Q2: Create completed_trips_view
--
-- Must return only completed trips with ALL of these columns:
--   trip_id, driver_name, rider_name,
--   pickup_city, dropoff_city,
--   fare_amount, distance_km, rating,
--   payment_method, requested_at, completed_at
--
-- No IDs in the output — use JOINs to resolve all foreign keys.
-- ─────────────────────────────────────────────────────────────────

-- YOUR VIEW HERE:
CREATE OR REPLACE VIEW completed_trips_view AS 
SELECT 
t.trip_id,
d.name AS driver_name,
p.name AS rider_name,
pck.city_name  AS pickup_city,
dst.city_name AS dropodd_city,
t.fare_amount,
t.distance_km,
t.rating,
pm.name AS payment_method,
t.requested_at,
t.completed_at
FROM trips t
INNER JOIN drivers  d
ON t.driver_id = d.driver_id
INNER JOIN passengers p 
ON t.passenger_id = p.passenger_id
INNER JOIN locations pck
ON t.pickup_location_id = pck.location_id
INNER JOIN locations dst 
ON t.dropoff_location_id = dst.location_id
INNER JOIN payment_methods pm
ON t.payment_method_id = pm.payment_method_id
WHERE t.status = 'completed';

-- Verify:
SELECT * FROM completed_trips_view LIMIT 5;


SELECT COUNT(*) FROM completed_trips_view;
-- Answer: 2862
-- Expected count: ~2862 (all completed trips)


-- ─────────────────────────────────────────────────────────────────
-- Q3: Create driver_summary view

-- Must show one row per driver with:
--   driver_name
--   total_trips          (all statuses)
--   completed_trips
--   cancelled_trips
--   cancellation_rate    (cancelled / total * 100, rounded to 1dp)
--   avg_fare             (completed trips only, rounded to 2dp)
--   avg_rating           (completed trips only, rounded to 1dp)
--
-- Challenge: use COUNT(*) FILTER (WHERE ...) instead of CASE WHEN
-- ─────────────────────────────────────────────────────────────────

-- YOUR VIEW HERE:
CREATE OR REPLACE VIEW driver_summary AS
SELECT d.name AS driver_name, 
count(t.trip_id) AS total_trips,
count(t.trip_id) FILTER (WHERE t.status = 'completed') AS completed_trips,
count(t.trip_id) FILTER (WHERE t.status = 'cancelled') AS cancelled_trips,
Round(count(t.trip_id) FILTER (WHERE t.status = 'cancelled') * 100.00/ NULLIF(count(t.trip_id), 0), 1) AS cancellation_rate,
Round(AVG(t.fare_amount) FILTER (WHERE t.status = 'completed'),2) AS avg_fare,
Round(AVG(t.rating) FILTER (WHERE t.status = 'completed'),1) AS avg_rating
FROM trips t 
INNER JOIN drivers d
ON t.driver_id = d.driver_id 
GROUP BY t.driver_id, d."name";

-- -----------------------------------------------------------Verify:
SELECT * FROM driver_summary ORDER BY completed_trips DESC;


-- ─────────────────────────────────────────────────────────────────
-- Q4: Transaction with intentional failure
--
-- Write a transaction that:
--   1. Inserts a new driver named 'Test Driver'
--   2. Inserts 3 valid trips for that driver
--   3. Inserts a 4th trip with rating = 99 (violates CHECK constraint)
-- The entire transaction should roll back.

--returns errors: SQL Error [23503]: ERROR: insert or update on table "trips" violates foreign key constraint "trips_payment_method_id_fkey"
--Detail: Key (payment_method_id)=(99) is not present in table "payment_methods".

-- Verify with: 
	SELECT * FROM drivers WHERE name = 'Test Driver';
-- Expected: 0 rows (atomicity — nothing committed)
-- ─────────────────────────────────────────────────────────────────

-- YOUR TRANSACTION HERE:
BEGIN;

INSERT INTO drivers(name) VALUES ('Test Driver');
INSERT INTO trips (driver_id,passenger_id,pickup_location_id,dropoff_location_id,
fare_amount,distance_km,status,requested_at,completed_at,rating,payment_method_id) VALUES
((SELECT driver_id FROM drivers WHERE name = 'Test Driver'),1,1,2,200.00,5.0,'completed',NOW(), NOW(),4.2,3);

INSERT INTO trips (driver_id,passenger_id,pickup_location_id,dropoff_location_id,
fare_amount,distance_km,status,requested_at,completed_at,rating,payment_method_id) VALUES
((SELECT driver_id FROM drivers WHERE name = 'Test Driver'),2,2,3,400.00,4.5,'completed',NOW(), NOW(),4.6,2);

INSERT INTO trips (driver_id,passenger_id,pickup_location_id,dropoff_location_id,
fare_amount,distance_km,status,requested_at,completed_at,rating,payment_method_id) VALUES
((SELECT driver_id FROM drivers WHERE name = 'Test Driver'),3,4,4,200.00,5.0,'completed',NOW(), NOW(),4.5,4);

INSERT INTO trips (driver_id,passenger_id,pickup_location_id,dropoff_location_id,
fare_amount,distance_km,status,requested_at,completed_at,rating,payment_method_id) VALUES
((SELECT driver_id FROM drivers WHERE name = 'Test Driver'),3,4,4,200.00,5.0,'completed',NOW(), NOW(),4.5,99);

COMMIT;

-- Verification query:
SELECT
    'drivers' AS tbl,
    COUNT(*) AS test_driver_rows
FROM drivers
WHERE name = 'Test Driver'
UNION ALL
SELECT 'trips', COUNT(*)
FROM trips t
JOIN drivers d ON t.driver_id = d.driver_id
WHERE d.name = 'Test Driver';

--Answer: drivers: 0, trips: 0
-- Expected: 0 / 0


-- ─────────────────────────────────────────────────────────────────
-- Q6 (STRETCH): Window function — running total fare per driver
--
-- For each completed trip, show:
--   trip_id, driver_name, requested_at, fare_amount,
--   running_total_fare (driver's cumulative fare up to this trip)
--
-- Use: SUM(fare_amount) OVER (PARTITION BY driver_id ORDER BY requested_at)
-- Order the final output by driver_name, requested_at
-- ─────────────────────────────────────────────────────────────────

-- YOUR QUERY HERE:
SELECT
    t.trip_id,
    d.name AS driver_name,
    t.requested_at,
    t.fare_amount,
    SUM(t.fare_amount) OVER (
        PARTITION BY t.driver_id
        ORDER BY t.requested_at
    ) AS running_total_fare
FROM trips t
JOIN drivers d ON t.driver_id = d.driver_id
WHERE t.status = 'completed'
ORDER BY d.name, t.requested_at;