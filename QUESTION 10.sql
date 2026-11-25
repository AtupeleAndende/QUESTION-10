-- ============================================================
-- Q10: SCHOLARSHIP APPLICATION ASSESSMENT
-- ============================================================

-- ---------- (a) DATABASE: TABLES ----------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------- (b) FUNCTION ----------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive: %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative: %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100: %', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- ---------- (c) PROCEDURE ----------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_app applications%ROWTYPE;
BEGIN
    SELECT * INTO v_app FROM applications WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application id: %', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)', p_application_id, v_app.status;
    END IF;

    UPDATE applications
    SET status = CASE WHEN fn_scholarship_eligible(v_app.age_at_application,
                                                   v_app.monthly_income,
                                                   v_app.average_mark)
                      THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END $$;

-- ---------- (d) TRIGGER ----------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO decision_audit(application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END $$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- ---------- (a) SEED DATA ----------
INSERT INTO students(student_number, full_name) VALUES
 ('S001','Student One'), ('S002','Student Two'), ('S003','Student Three');

INSERT INTO applications(student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
 (1, 18, 3000.00, 70.00, '2026-11-01'),  -- boundary: qualifies
 (1, 25, 2500.00, 85.00, '2026-11-02'),  -- upper age boundary: qualifies
 (2, 17, 1000.00, 90.00, '2026-11-03'),  -- too young
 (2, 26, 1500.00, 88.00, '2026-11-04'),  -- too old
 (3, 22, 3000.01, 80.00, '2026-11-05'),  -- income just over
 (3, 22, 2000.00, 69.99, '2026-11-06');  -- mark just under

-- ---------- (e) VIEW ----------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- ---------- (f) INDEX ----------
-- Equality column (status) first, range column (submitted_on) second.
CREATE INDEX idx_applications_status_submitted ON applications(status, submitted_on);

-- SET enable_seqscan = off;
EXPLAIN
SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';

-- ---------- (g) SCHEDULED JOB ----------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications
             WHERE status = 'PENDING' ORDER BY application_id LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END $$;
-- A rerun finds no PENDING rows, so nothing is reassessed and no audit rows are duplicated.

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('assess_pending', '0 8 * * 1', $$CALL pr_assess_pending()$$);

-- Test: run now, then run again
CALL pr_assess_pending();
CALL pr_assess_pending();   -- no effect
SELECT * FROM v_approved_applicants;
SELECT * FROM decision_audit;