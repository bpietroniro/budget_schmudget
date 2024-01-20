-- DROP DATABASE budgetapp;

-- CREATE DATABASE budgetapp;

-- \connect budgetapp

CREATE EXTENSION pgcrypto;

CREATE TABLE users (
    id serial PRIMARY KEY,
    username text,
    password_hash text
);

CREATE TABLE budgets (
    id serial PRIMARY KEY,
    user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    total numeric NOT NULL,
    uncategorized numeric NOT NULL,
    month integer,
    year integer,
    CONSTRAINT budgets_month_check CHECK (((month >= 1) AND (month <= 12))),
    CONSTRAINT budgets_total_check CHECK ((total > (0)::numeric)),
    CONSTRAINT budgets_uncategorized_check CHECK ((uncategorized >= (0)::numeric)),
    CONSTRAINT budgets_year_check CHECK ((year > 0))
    CONSTRAINT one_budget_per_user_per_month UNIQUE (user_id, month, year)
);

CREATE TABLE categories (
    id serial PRIMARY KEY,
    budget_id integer NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
    name text NOT NULL,
    allocation numeric DEFAULT 0 NOT NULL,
    CONSTRAINT categories_allocation_check CHECK ((allocation >= (0)::numeric))
    CONSTRAINT categories_name_and_budget_key UNIQUE (name, budget_id)
);

CREATE TABLE expenses (
    id serial PRIMARY KEY,
    category_id integer NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    description text NOT NULL,
    amount numeric NOT NULL,
    transaction_date date DEFAULT CURRENT_DATE NOT NULL,
    CONSTRAINT expenses_amount_check CHECK ((amount > (0)::numeric))
);
