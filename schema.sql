DROP DATABASE budgetapp;

CREATE DATABASE budgetapp;

\connect budgetapp

CREATE TABLE budgets (
    id serial PRIMARY KEY,
    total numeric NOT NULL CHECK (total >= 0),
    uncategorized numeric NOT NULL CHECK (uncategorized >= 0)
);

CREATE TABLE categories (
    id serial PRIMARY KEY,
    budget_id integer NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
    name text NOT NULL,
    allocation numeric DEFAULT 0 NOT NULL CHECK (allocation >= 0),
    CONSTRAINT categories_name_and_budget_key UNIQUE (name, budget_id)
);

CREATE TABLE expenses (
    id serial PRIMARY KEY,
    category_id integer NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    description text NOT NULL,
    amount numeric NOT NULL CHECK (amount > 0),
    transaction_date date DEFAULT CURRENT_DATE NOT NULL
);
