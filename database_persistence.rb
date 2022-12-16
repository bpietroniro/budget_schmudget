require "pg"

class DatabasePersistence
  def initialize(logger)
    @db = PG.connect(dbname: "budgetapp")
    @logger = logger
  end

  def query(statement, *params)
    @logger.info "#{statement}: #{params}"
    @db.exec_params(statement, params)
  end

  def budget_info(budget_id)
    sql = <<~SQL
      SELECT total, uncategorized
      FROM budgets
      WHERE id = $1
    SQL
    result = query(sql, budget_id)
    tuple = result.first
    { total: tuple["total"], uncategorized: tuple["uncategorized"] }
  end

  # to be used only if "all_categories" hasn't already been called in the route
  def total_expenses(budget_id)
    sql = <<~SQL
      SELECT COALESCE(SUM(expenses.amount), 0)
      FROM categories
      JOIN expenses ON categories.id = expenses.category_id
      WHERE categories.budget_id = $1
      GROUP BY categories.budget_id;
    SQL

    result = query(sql, budget_id)
    result.first["coalesce"]
  end

  def get_category_id(category_name, budget_id)
    # there might be a better way to implement case insensitivity,
    # but I haven't found it yet
    sql = "SELECT id FROM categories WHERE name ILIKE $1 AND budget_id = $2"

    result = query(sql, category_name, budget_id)
    result.first["id"]
  end

  def get_remaining_funds(category_id)
    sql = <<~SQL
      SELECT categories.allocation, COALESCE(SUM(expenses.amount), 0) 
        AS "spent"
      FROM categories
      LEFT JOIN expenses ON expenses.category_id = categories.id
      WHERE categories.id = $1
      GROUP BY categories.id;
    SQL

    result = query(sql, category_id)
    tuple = result.first
    tuple["allocation"].to_f - tuple["spent"].to_f
  end

  # this will need to change once there's more than one user
  def category_info(id)
    sql = <<~SQL
      SELECT categories.name,
             categories.id,
             categories.allocation,
             COALESCE(SUM(expenses.amount), 0) AS "spent"
      FROM categories
      LEFT JOIN expenses ON expenses.category_id = categories.id
      WHERE categories.id = $1
      GROUP BY categories.id;
    SQL

    result = query(sql, id)
    p "result: #{result}"
    tuple = result.first
    p "tuple: #{tuple}"
    tuple_to_category_hash(tuple)
  end

  def category_expenses(id)
    sql = <<~SQL
      SELECT expenses.id, description, amount, date
      FROM expenses
      JOIN categories ON category_id = categories.id
      WHERE categories.id = $1
    SQL

    result = query(sql, id)
    result.map do |tuple|
      { id: tuple["id"],
        description: tuple["description"],
        amount: tuple["amount"].to_f,
        date: tuple["date"] }
    end
  end

  def all_categories(budget_id)
    sql = <<~SQL
      SELECT categories.name, categories.id, categories.allocation,
             COALESCE(SUM(expenses.amount), 0) AS "spent"
      FROM categories LEFT JOIN expenses ON expenses.category_id = categories.id
      WHERE budget_id = $1 GROUP BY categories.id
    SQL

    result = query(sql, budget_id)
    result.map do |tuple|
      tuple_to_category_hash(tuple)
    end
  end

  # N.B. need to downcase name before storing??
  def create_new_category(name, allocation, budget_id)
    sql = <<~SQL
      INSERT INTO categories (name, allocation, budget_id) VALUES ($1, $2, $3)
    SQL

    query(sql, name, allocation, budget_id)
  end

  def pull_funds_from_category(category_id, amount)
    sql = <<~SQL
      UPDATE categories SET allocation = allocation - $1
      WHERE categories.id = $2
    SQL

    query(sql, amount, category_id)
  end

  def pull_funds_from_uncategorized(budget_id, amount)
    sql = <<~SQL
      UPDATE budgets SET uncategorized = uncategorized - $1
      WHERE id = $2
    SQL

    query(sql, amount, budget_id)
  end

  def log_expense(category_id, description, cost, date)
    sql = <<~SQL
      INSERT INTO expenses (category_id, description, amount, date)
      VALUES ($1, $2, $3, $4)
    SQL

    query(sql, category_id, description, cost, date)
  end

  def delete_category(category_id)
    # get the amount currently allocated to the category
    sql = "SELECT allocation, budget_id FROM categories WHERE id = $1"
    result = query(sql, category_id).first
    transfer_amount = result["allocation"]
    budget_id = result["budget_id"]

    # transfer this amount back to "uncategorized" amount in the budget
    sql = <<~SQL
      UPDATE budgets SET uncategorized = uncategorized + $1
      WHERE id = $2
    SQL
    query(sql, transfer_amount, budget_id)

    # finally, delete the category record
    # (this should delete all associated expenses automatically)
    sql = "DELETE FROM categories WHERE id = $1"

    query(sql, category_id)
  end

  def delete_expense(id)
    sql = "DELETE FROM expenses WHERE id = $1"

    query(sql, id)
  end

  def disconnect
    @db.close
  end

  private

  def tuple_to_category_hash(tuple)
    { name: tuple["name"],
      id: tuple["id"],
      total: tuple["allocation"].to_f,
      spent: tuple["spent"].to_f,
      remaining: tuple["allocation"].to_f - tuple["spent"].to_f }
  end
end
