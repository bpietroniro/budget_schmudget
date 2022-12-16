CREATE TABLE users (
  id serial PRIMARY KEY,
  username text
);

CREATE TABLE budgets (
  id serial PRIMARY KEY,
  user_id int REFERENCES users (id),
  total numeric NOT NULL CHECK (total > 0),
  uncategorized numeric NOT NULL CHECK (uncategorized >= 0)
);

CREATE TABLE categories (
  id serial PRIMARY KEY,
  budget_id int NOT NULL REFERENCES budgets (id),
  name text UNIQUE NOT NULL,
  allocation numeric NOT NULL DEFAULT 0 CHECK (allocation >= 0)
);

CREATE TABLE expenses (
  description text NOT NULL,
  amount numeric NOT NULL CHECK (amount > 0),
  category_id int NOT NULL REFERENCES categories (id)
);
