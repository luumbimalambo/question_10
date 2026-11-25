-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- Student: Luumbi Malambo | Student No: 202408554

DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id      SERIAL PRIMARY KEY,
    student_id          INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application  INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE NOT NULL,
    status              VARCHAR(10) NOT NULL DEFAULT 'PENDING',
    CONSTRAINT chk_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('202400301', 'Hope Mwila'),
    ('202400302', 'Ian Kalaba'),
    ('202400303', 'Joyce Mpundu');

-- Six PENDING applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 20, 2500.00, 85.00, CURRENT_DATE - 10),   -- qualifies
    (1, 17, 2000.00, 90.00, CURRENT_DATE - 9),    -- too young
    (2, 18, 3000.00, 70.00, CURRENT_DATE - 8),    -- ALL boundaries met -> qualifies
    (2, 25, 3000.01, 80.00, CURRENT_DATE - 7),    -- income just above limit
    (3, 26, 1000.00, 75.00, CURRENT_DATE - 6),    -- too old
    (3, 22, 2800.00, 69.99, CURRENT_DATE - 5);    -- mark just below limit

SELECT * FROM applications ORDER BY application_id;

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_app      applications%ROWTYPE;
    v_eligible BOOLEAN;
BEGIN
    SELECT * INTO v_app FROM applications
    WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)',
            p_application_id, v_app.status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_app.age_at_application,
                                          v_app.monthly_income,
                                          v_app.average_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_decision_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (OLD.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION trg_decision_audit();

-- Tests
SELECT fn_scholarship_eligible(20, 2500, 85)   AS qualifies,        -- t
       fn_scholarship_eligible(18, 3000, 70)   AS all_boundaries,   -- t
       fn_scholarship_eligible(25, 3000.01, 80) AS income_over,     -- f
       fn_scholarship_eligible(17, 1000, 90)   AS too_young;        -- f
DO $$
BEGIN
    BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

CALL pr_assess_application(1);       -- assess one application directly
SELECT application_id, status FROM applications ORDER BY application_id;
DO $$
BEGIN
    BEGIN CALL pr_assess_application(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_assess_application(1);      -- already assessed
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;
UPDATE applications SET average_mark = average_mark WHERE application_id = 1;  -- status unchanged
SELECT * FROM decision_audit;                -- still only one audit row

-- (g) pr_assess_pending (defined here because the view/index tests below use its result)
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications
             WHERE status = 'PENDING' ORDER BY application_id     -- PENDING only
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();
SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;
SELECT COUNT(*) AS audit_rows FROM decision_audit;     -- 6 (one per application)

CALL pr_assess_pending();                              -- rerun: nothing reassessed
SELECT COUNT(*) AS audit_rows_after_rerun FROM decision_audit;   -- still 6

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status   -- income is NOT exposed
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;

-- (f) Index ----------------------------------------------------------------
-- Equality on status, then a range on submitted_on -> composite (status, submitted_on).
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;
SET enable_seqscan = off;   -- tiny table: force the plan to show the index
EXPLAIN
SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job: every Monday at 08:00 -------------------------------------
-- Scheduling with pg_cron. If pg_cron is not installed, this prints a notice instead
-- of failing, so the rest of the script is not rolled back.
DO $do$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('assess_pending_weekly', '0 8 * * 1',
        $$CALL pr_assess_pending()$$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, job not scheduled: %', SQLERRM;
END $do$;

-- Inspect the job (works only where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, runid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
