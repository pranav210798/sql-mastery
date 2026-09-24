-- ============================================================================
-- company_db — canonical sample database for the SQL Mastery Course
-- Used in: Chapters 1-24 (foundations through triggers), Project 1
-- Dialect: PostgreSQL (primary). Dialect notes for MySQL/Oracle/SQL Server
-- appear inline in course chapters, not here.
-- ============================================================================

DROP SCHEMA IF EXISTS company_db CASCADE;
CREATE SCHEMA company_db;
SET search_path TO company_db;

-- ----------------------------------------------------------------------------
-- Table: departments
-- ----------------------------------------------------------------------------
CREATE TABLE departments (
    department_id   SERIAL PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL UNIQUE,
    location        VARCHAR(100),
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- Table: employees
-- Self-referencing FK (manager_id -> employees.employee_id) enables
-- hierarchy / recursive CTE examples later in the course.
-- ----------------------------------------------------------------------------
CREATE TABLE employees (
    employee_id     SERIAL PRIMARY KEY,
    first_name      VARCHAR(50) NOT NULL,
    last_name       VARCHAR(50) NOT NULL,
    email           VARCHAR(150) NOT NULL UNIQUE,
    hire_date       DATE NOT NULL,
    job_title       VARCHAR(100) NOT NULL,
    department_id   INT REFERENCES departments(department_id) ON DELETE SET NULL,
    manager_id      INT REFERENCES employees(employee_id) ON DELETE SET NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','ON_LEAVE','TERMINATED')),
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- Table: managers
-- One row per department identifying the managing employee.
-- (Deliberately denormalized vs. employees.manager_id so we have a real
-- one-to-one relationship to teach 1:1 modelling and its trade-offs.)
-- ----------------------------------------------------------------------------
CREATE TABLE managers (
    manager_id      INT PRIMARY KEY REFERENCES employees(employee_id),
    department_id   INT NOT NULL UNIQUE REFERENCES departments(department_id),
    appointed_date  DATE NOT NULL
);

-- ----------------------------------------------------------------------------
-- Table: salaries
-- One employee can have multiple salary rows over time (salary history).
-- ----------------------------------------------------------------------------
CREATE TABLE salaries (
    salary_id       SERIAL PRIMARY KEY,
    employee_id     INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    base_salary     NUMERIC(10,2) NOT NULL CHECK (base_salary > 0),
    bonus           NUMERIC(10,2) NOT NULL DEFAULT 0,
    currency        CHAR(3) NOT NULL DEFAULT 'USD',
    effective_date  DATE NOT NULL,
    UNIQUE (employee_id, effective_date)
);

-- ----------------------------------------------------------------------------
-- Table: attendance
-- ----------------------------------------------------------------------------
CREATE TABLE attendance (
    attendance_id   SERIAL PRIMARY KEY,
    employee_id     INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    work_date       DATE NOT NULL,
    status          VARCHAR(20) NOT NULL CHECK (status IN ('PRESENT','ABSENT','LATE','REMOTE','LEAVE')),
    check_in        TIME,
    check_out       TIME,
    UNIQUE (employee_id, work_date)
);

-- ----------------------------------------------------------------------------
-- Table: projects
-- ----------------------------------------------------------------------------
CREATE TABLE projects (
    project_id      SERIAL PRIMARY KEY,
    project_name    VARCHAR(150) NOT NULL,
    department_id   INT REFERENCES departments(department_id),
    start_date      DATE NOT NULL,
    end_date        DATE,
    budget          NUMERIC(12,2) CHECK (budget >= 0),
    CHECK (end_date IS NULL OR end_date >= start_date)
);

-- ----------------------------------------------------------------------------
-- Table: employee_projects (many-to-many bridge)
-- ----------------------------------------------------------------------------
CREATE TABLE employee_projects (
    employee_id     INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    project_id      INT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    role            VARCHAR(100) NOT NULL,
    hours_allocated INT NOT NULL DEFAULT 0 CHECK (hours_allocated >= 0),
    PRIMARY KEY (employee_id, project_id)
);

-- ============================================================================
-- SEED DATA
-- ============================================================================

INSERT INTO departments (department_id, department_name, location) VALUES
(1, 'Engineering', 'Pune'),
(2, 'Sales',       'Mumbai'),
(3, 'HR',          'Bengaluru'),
(4, 'Finance',     'Mumbai'),
(5, 'Marketing',   'Delhi');
SELECT setval('departments_department_id_seq', 5);

INSERT INTO employees (employee_id, first_name, last_name, email, hire_date, job_title, department_id, manager_id, status) VALUES
(1,  'Aditi',  'Rao',      'aditi.rao@company.com',      '2015-03-01', 'CTO',                 1, NULL, 'ACTIVE'),
(2,  'Rahul',  'Mehta',    'rahul.mehta@company.com',    '2016-05-12', 'Engineering Manager', 1, 1,    'ACTIVE'),
(3,  'Sneha',  'Kulkarni', 'sneha.kulkarni@company.com', '2017-01-20', 'Senior Engineer',     1, 2,    'ACTIVE'),
(4,  'Vikram', 'Joshi',    'vikram.joshi@company.com',   '2018-07-15', 'Software Engineer',   1, 2,    'ACTIVE'),
(5,  'Ananya', 'Singh',    'ananya.singh@company.com',   '2019-09-01', 'Software Engineer',   1, 2,    'ON_LEAVE'),
(6,  'Karan',  'Verma',    'karan.verma@company.com',    '2020-02-10', 'Junior Engineer',     1, 3,    'ACTIVE'),
(7,  'Priya',  'Nair',     'priya.nair@company.com',     '2015-11-05', 'Sales Manager',       2, 1,    'ACTIVE'),
(8,  'Arjun',  'Das',      'arjun.das@company.com',      '2017-04-18', 'Sales Executive',     2, 7,    'ACTIVE'),
(9,  'Meera',  'Pillai',   'meera.pillai@company.com',   '2021-03-22', 'Sales Executive',     2, 7,    'TERMINATED'),
(10, 'Rohan',  'Kapoor',   'rohan.kapoor@company.com',   '2016-08-09', 'HR Manager',          3, 1,    'ACTIVE'),
(11, 'Isha',   'Bhatt',    'isha.bhatt@company.com',     '2019-01-14', 'HR Executive',        3, 10,   'ACTIVE'),
(12, 'Nikhil', 'Gupta',    'nikhil.gupta@company.com',   '2016-12-01', 'Finance Manager',     4, 1,    'ACTIVE'),
(13, 'Divya',  'Shah',     'divya.shah@company.com',     '2018-06-25', 'Accountant',          4, 12,   'ACTIVE'),
(14, 'Rajesh', 'Iyer',     'rajesh.iyer@company.com',    '2017-09-30', 'Marketing Manager',   5, 1,    'ACTIVE'),
(15, 'Pooja',  'Reddy',    'pooja.reddy@company.com',    '2020-10-05', 'Marketing Executive', 5, 14,   'ACTIVE'),
(16, 'Aman',   'Chawla',   'aman.chawla@company.com',    '2022-01-10', 'Software Engineer',   1, 2,    'ACTIVE');
SELECT setval('employees_employee_id_seq', 16);

INSERT INTO managers (manager_id, department_id, appointed_date) VALUES
(1,  1, '2015-03-01'),
(7,  2, '2015-11-05'),
(10, 3, '2016-08-09'),
(12, 4, '2016-12-01'),
(14, 5, '2017-09-30');

-- Salary history: multiple rows per employee over time
INSERT INTO salaries (employee_id, base_salary, bonus, effective_date) VALUES
(1, 450000, 90000, '2015-03-01'), (1, 520000, 100000, '2020-01-01'),
(2, 280000, 40000, '2016-05-12'), (2, 320000, 50000, '2021-01-01'),
(3, 180000, 20000, '2017-01-20'), (3, 210000, 25000, '2022-01-01'),
(4, 120000, 10000, '2018-07-15'), (4, 140000, 12000, '2022-01-01'),
(5, 120000, 10000, '2019-09-01'),
(6,  80000,  5000, '2020-02-10'),
(7, 260000, 60000, '2015-11-05'), (7, 300000, 70000, '2021-01-01'),
(8, 110000, 30000, '2017-04-18'),
(9,  95000, 10000, '2021-03-22'),
(10, 240000, 30000, '2016-08-09'),
(11, 100000, 8000, '2019-01-14'),
(12, 250000, 35000, '2016-12-01'),
(13, 130000, 12000, '2018-06-25'),
(14, 230000, 28000, '2017-09-30'),
(15, 105000, 9000, '2020-10-05'),
(16,  95000, 6000, '2022-01-10');

-- Attendance sample for first two weeks of Jan 2024
INSERT INTO attendance (employee_id, work_date, status, check_in, check_out) VALUES
(3, '2024-01-01', 'PRESENT', '09:05', '18:10'),
(3, '2024-01-02', 'PRESENT', '09:00', '18:00'),
(3, '2024-01-03', 'LATE',    '10:15', '18:30'),
(4, '2024-01-01', 'PRESENT', '09:10', '18:00'),
(4, '2024-01-02', 'ABSENT',  NULL,    NULL),
(4, '2024-01-03', 'PRESENT', '09:00', '17:55'),
(5, '2024-01-01', 'LEAVE',   NULL,    NULL),
(5, '2024-01-02', 'LEAVE',   NULL,    NULL),
(6, '2024-01-01', 'REMOTE',  '09:00', '17:30'),
(6, '2024-01-02', 'PRESENT', '09:20', '18:20');

INSERT INTO projects (project_id, project_name, department_id, start_date, end_date, budget) VALUES
(1, 'Platform Migration',    1, '2023-01-01', '2023-12-31', 5000000),
(2, 'Mobile App Revamp',     1, '2024-01-15', NULL,         3000000),
(3, 'Q1 Sales Expansion',    2, '2024-01-01', '2024-03-31', 1200000),
(4, 'Employee Wellness',     3, '2023-06-01', '2023-09-30',  250000),
(5, 'Brand Relaunch',        5, '2024-02-01', NULL,          800000);
SELECT setval('projects_project_id_seq', 5);

INSERT INTO employee_projects (employee_id, project_id, role, hours_allocated) VALUES
(2, 1, 'Tech Lead',        400),
(3, 1, 'Senior Engineer',  600),
(4, 1, 'Engineer',         500),
(2, 2, 'Tech Lead',        300),
(6, 2, 'Engineer',         450),
(16,2, 'Engineer',         450),
(7, 3, 'Sales Lead',       200),
(8, 3, 'Sales Executive',  350),
(10,4, 'HR Lead',          150),
(11,4, 'Coordinator',      200),
(14,5, 'Marketing Lead',   250),
(15,5, 'Executive',        300);
