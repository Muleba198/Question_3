DROP VIEW IF EXISTS v_overdue_loans CASCADE;
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables & Seed Data
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(200) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on   DATE NULL CHECK (returned_on IS NULL OR returned_on >= borrowed_on),
    fine_amount   NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0 CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Clean Code'),
    ('Operating System Concepts');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Mutale Banda',   '2026-10-01', '2026-10-15', NULL,         0.00),
    (1, 'Tisa Phiri',     '2026-10-05', '2026-10-20', NULL,         0.00),
    (2, 'Mwape Zulu',     '2026-11-01', '2026-11-15', '2026-11-15', 0.00),
    (2, 'Bwalya Mwila',   '2026-10-10', '2026-10-20', '2026-10-25', 10.00),
    (3, 'Chilufya Kunda', '2026-11-18', '2026-12-02', NULL,         0.00),
    (3, 'Kondwani Tembo', '2026-11-10', '2026-11-24', NULL,         0.00);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of   DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on      DATE;
    v_returned_on DATE;
    v_effective   DATE;
    v_days_late   INTEGER;
BEGIN
    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_effective := COALESCE(p_as_of, CURRENT_DATE);
    IF v_returned_on IS NOT NULL AND v_returned_on < v_effective THEN
        v_effective := v_returned_on;
    END IF;

    v_days_late := GREATEST(0, (v_effective - v_due_on));
    RETURN (v_days_late * 2)::NUMERIC(10, 2);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id     INTEGER,
    p_returned_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_due_on      DATE;
    v_returned_on DATE;
    v_fine        NUMERIC(10, 2);
BEGIN
    SELECT borrowed_on, due_on, returned_on
    INTO v_borrowed_on, v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % is already returned on %', p_loan_id, v_returned_on;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date (%) cannot be before borrowed date (%)', p_returned_on, v_borrowed_on;
    END IF;

    v_fine := GREATEST(0, (p_returned_on - v_due_on)) * 2;

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_log_loan_return_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_returned_on_audit
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION fn_log_loan_return_change();

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title AS book_title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index & EXPLAIN
CREATE INDEX idx_loans_book_unreturned
ON loans (book_id)
WHERE returned_on IS NULL;

EXPLAIN (ANALYZE, BUFFERS)
SELECT loan_id, book_id, borrower_name, borrowed_on, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

-- (g) Refresh Procedure & Schedule
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_overdue_count INTEGER;
    v_total_fine    NUMERIC(12, 2);
BEGIN
    SELECT
        COUNT(*),
        COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    INTO v_overdue_count, v_total_fine
    FROM loans
    WHERE returned_on IS NULL
      AND due_on < p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_overdue_count, v_total_fine)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;

