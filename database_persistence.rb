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

  def create_new_budget(total)
    sql = "INSERT INTO budgets (total, uncategorized) VALUES ($1, $1)"
    query(sql, total)
  end

  def update_budget(difference)
    sql = if difference < 0
            difference = -1 * difference
            "UPDATE budgets SET total = total - $1, uncategorized = uncategorized - $1 WHERE id = 1"
          else
            "UPDATE budgets SET total = total + $1, uncategorized = uncategorized + $1 WHERE id = 1"
          end
    query(sql, difference)
  end

  # Fetch info for the overall budget, independent of categories
  def budget_info(budget_id)
    sql = <<~SQL
      SELECT total, uncategorized
      FROM budgets
      WHERE id = $1
    SQL
    result = query(sql, budget_id)
    tuple = result.first
    return nil unless tuple
    { total: tuple["total"], uncategorized: tuple["uncategorized"] }
  end

  # Fetch list of categories for each page of the budget overview
  def paginated_category_list(budget_id, offset)
    sql = <<~SQL
      SELECT categories.name, categories.id, categories.allocation,
             COALESCE(SUM(expenses.amount), 0) AS "spent"
      FROM categories LEFT JOIN expenses ON expenses.category_id = categories.id
      WHERE budget_id = $1 GROUP BY categories.id
      ORDER BY LOWER(name), allocation
      LIMIT 5 OFFSET $2
    SQL

    result = query(sql, budget_id, offset)
    result.map do |tuple|
      tuple_to_category_hash(tuple)
    end
  end

  # Fetch all categories (independent of pagination)
  def category_list(budget_id)
    sql = <<~SQL
      SELECT categories.name, categories.id, categories.allocation,
      COALESCE(SUM(expenses.amount), 0) AS "spent"
      FROM categories LEFT JOIN expenses ON expenses.category_id = categories.id
      WHERE budget_id = $1 GROUP BY categories.id ORDER BY LOWER(name)
    SQL

    result = query(sql, budget_id)
    result.map do |tuple|
      tuple_to_category_hash(tuple)
    end
  end

  # Generate total spent, total remaining, and total category count
  # for the whole budget (independent of pagination or individual categories)
  def category_totals(budget_id)
    sql = <<~SQL
      SELECT COALESCE(SUM(categories.allocation) OVER (), 0) AS "total_allocated",
      SUM(COALESCE(SUM(expenses.amount), 0)) OVER() AS "total_spent",
      COUNT(categories.id) OVER() as "category_count"
      FROM categories LEFT JOIN expenses ON expenses.category_id = categories.id
      WHERE budget_id = $1 GROUP BY categories.id LIMIT 1;
    SQL

    tuple = query(sql, budget_id).first
    return { spent: 0, remaining: 0, category_count: 0 } unless tuple
    { spent: tuple["total_spent"],
      remaining: tuple["total_allocated"].to_f - tuple["total_remaining"].to_f,
      category_count: tuple["category_count"] }
  end

  # Fetch info for an individual category
  def category_info(id)
    sql = <<~SQL
      SELECT categories.name, categories.id, categories.allocation,
             COALESCE(SUM(expenses.amount), 0) AS "spent",
             COUNT(expenses.id)
      FROM categories LEFT JOIN expenses ON expenses.category_id = categories.id
      WHERE categories.id = $1 GROUP BY categories.id;
    SQL

    tuple = query(sql, id).first
    return nil unless tuple
    tuple_to_category_hash(tuple).merge({ expense_count: tuple["count"] })
  end

  def create_new_category(name, allocation, budget_id, source)
    if source == "uncategorized"
      pull_funds_from_uncategorized(budget_id, allocation)
    else
      pull_funds_from_category(source, allocation)
    end
    sql = <<~SQL
      INSERT INTO categories (name, allocation, budget_id) VALUES ($1, $2, $3)
    SQL

    query(sql, name, allocation, budget_id)
  end

  def update_category(id, name, allocation, source, difference)
    if difference > 0
      if source == "uncategorized"
        pull_funds_from_uncategorized(1, difference)
      else pull_funds_from_category(source.to_i, difference) end
    else
      difference = -1 * difference
      sql = "UPDATE budgets SET uncategorized = uncategorized + $1 WHERE id = 1"
      query(sql, difference) end

    sql = "UPDATE categories SET name = $1, allocation = $2 WHERE id = $3"
    query(sql, name, allocation, id)
  end

  def delete_category(category_id)
    # get the amount currently allocated to the category
    sql = "SELECT allocation, budget_id FROM categories WHERE id = $1"
    result = query(sql, category_id).first
    transfer_amount = result["allocation"]
    budget_id = result["budget_id"]

    # transfer this amount back to "uncategorized" amount in the budget
    sql = "UPDATE budgets SET uncategorized = uncategorized + $1 WHERE id = $2"
    query(sql, transfer_amount, budget_id)

    # finally, delete the category record
    # (this deletes all associated expenses automatically)
    sql = "DELETE FROM categories WHERE id = $1"

    query(sql, category_id)
  end

  # Fetch list of expenses for each page of a category overview
  def paginated_expenses(category_id, offset)
    sql = <<~SQL
      SELECT expenses.id, description, amount, transaction_date FROM expenses
      JOIN categories ON category_id = categories.id WHERE categories.id = $1
      ORDER BY transaction_date, amount LIMIT 5 OFFSET $2
    SQL

    result = query(sql, category_id, offset)
    result.map do |tuple|
      tuple_to_expenses_hash(tuple)
    end
  end

  def log_expense(category_id, description, amount, date)
    sql = <<~SQL
      INSERT INTO expenses (category_id, description, amount, transaction_date)
      VALUES ($1, $2, $3, $4)
    SQL

    query(sql, category_id, description, amount, date)
  end

  def update_expense(id, description, amount, date)
    sql = <<~SQL
      UPDATE expenses
      SET description = $1, amount = $2, transaction_date = $3
      WHERE id = $4
    SQL

    query(sql, description, amount, date, id)
  end

  def delete_expense(id)
    sql = "DELETE FROM expenses WHERE id = $1"

    query(sql, id)
  end

  def disconnect
    @db.close
  end

  private

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

  def tuple_to_category_hash(tuple)
    { name: tuple["name"],
      id: tuple["id"],
      total: tuple["allocation"].to_f,
      spent: tuple["spent"].to_f,
      remaining: tuple["allocation"].to_f - tuple["spent"].to_f }
  end

  def tuple_to_expenses_hash(tuple)
    { id: tuple["id"],
      description: tuple["description"],
      amount: tuple["amount"].to_f,
      date: tuple["transaction_date"] }
  end
end
