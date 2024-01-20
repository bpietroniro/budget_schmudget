require "sinatra"
require "sinatra/content_for"
require "tilt/erubis"

require_relative "database_persistence"

configure do
  enable :sessions
  set :session_secret, "3619d4361dc051e2b3e889b4e873854348890d8dfa8efa4e8aa2657296948e6c" 
end

configure do
  set :erb, :escape_html => true
end

configure(:development) do
  require "sinatra/reloader"
  also_reload "database_persistence.rb"
end

helpers do
  def format_currency(amount)
    "$" + format("%.2f", amount)
  end

  # Display remaining amount in red if over the budget limit
  def remaining_amount_class(amount)
    "red" if amount.to_f < 0
  end

  # For pagination
  def number_of_pages(item_count)
    (item_count.to_i / 5.0).ceil
  end

  def disable_previous?(current_page)
    current_page.to_i == 1
  end

  def disable_next?(current_page, item_count)
    current_page == number_of_pages(item_count)
  end
end

# Determines whether a budget already exists in the database
def load_budget(id)
  budget = @storage.budget_info(id)
  return budget if budget
  redirect "/budget/new"
end

# Attempts to load category info by id from the database
def load_category(id)
  unless id =~ /^[0-9]+$/
    redirect not_found
  end
  category = @storage.category_info(id)
  return category if category
  session[:load_error] = "The specified category was not found."
  redirect "/budget"
end

# This method is redundant at the moment, but will be
# elaborated on in future version of the project
def create_new_category(name, allocation, budget_id, source)
  @storage.create_new_category(name, allocation, budget_id, source)
end

# Calculates "remaining" for the overall budget based on the sum
# of "spent" from all categories (this ensures accuracy if any
# individual categories are "in the red")
def merge_budget_info(budget, totals)
  remaining = budget[:total].to_f - totals[:spent].to_f
  budget.merge({ spent: totals[:spent], remaining: remaining.to_s })
end

def validate_expense(id, expense_list)
  return if expense_list.map { |expense| expense[:id].to_i }.include?(id.to_i)
  session[:load_error] = "The specified expense could not be found."
  redirect "/budget"
end

def error_for_page_number(item_list, page_number)
  if page_number > 1 && item_list.empty?
    session[:page_error] = "Looks like that page doesn't exist. Here's the first page!"
    redirect request.path
  end
end

def error_for_numeric_input(value_string)
  if !(value_string =~ /^[0-9]*($|\.[0-9]{1,2}$)/)
    "Please enter a monetary value (dollars and cents)."
  elsif value_string.to_f == 0.0
    "Please enter a value greater than 0 for the amount."
  end
end

def error_insufficient_funds
  <<~MESSAGE
      Oops, there aren't enough funds in the source you chose!
      You have a few options:
      1) Choose a different source,
      2) Allocate fewer funds, or
      3) Allocate fewer funds for now, and then add more later from a different source.
  MESSAGE
end

def error_for_category_name(name, list_of_categories)
  if !(1..100).cover? name.strip.size
    "The name must be between 1-100 characters long."
  elsif list_of_categories.map { |category| category[:name] }.include?(name)
    "The category name must be unique. Please choose another name."
  end
end

def error_for_description(description)
  if !(1..100).cover? description.strip.size
    "The description must be between 1-100 characters long."
  end
end

def error_for_new_budget_total
  <<~MESSAGE
    Oops! Not enough uncategorized funds.
    Please choose a higher total, or re-route some funds from your categories.
  MESSAGE
end

# Determine whether a user is already signed in
def signed_in?
  session.key?(:username)
end

# Initialize database connection
before do
  @storage = DatabasePersistence.new(logger)
end

# If nobody is signed in, save the requested path in the session data
# and redirect to the signin page
before "/budget*" do
  unless signed_in?
    session[:path] = request.path
    redirect "/signin"
  end
end

# Close database connection
after do
  @storage.disconnect
end

# Route error handling
not_found do
  session[:error] = "We couldn't find that page, sorry!"
  redirect "/"
end

# Home page
get "/" do
  erb :home, layout: :layout
end

# Display sign-in page
get "/signin" do
  erb :signin
end

# Attempt to sign in
post "/signin" do
  if params[:username] == "HRM" && params[:password] == "SweetDeetEmpire"
    session[:username] = params[:username]
    if session[:path]
      redirect session[:path]
    else
      redirect "/budget"
    end
  else
    session[:error] = "Incorrect username or password."
    erb :signin
  end
end

# Sign out
post "/signout" do
  session.delete(:username)
  redirect "/"
end

# Create a new budget (for now, this is only available if there is not
# already a budget in the database)
get "/budget/new" do
  redirect "/budget" if @storage.budget_info(1)
  erb :new, layout: :layout
end

# Store new budget in the database
post "/budget/new" do
  budget_total = params[:budget_total]
  error = error_for_numeric_input(budget_total)
  if error
    session[:error] = error
    erb :new, layout: :layout
  else
    @storage.create_new_budget(budget_total)
    redirect "/budget"
  end
end

# Common routing error
get "/budget/" do
  redirect "/budget"
end

# Display budget overview page
get "/budget" do
  @page = params[:page] ? params[:page].to_i : 1
  @budget = load_budget(1)
  @categories_for_page = @storage.paginated_category_list(1, (@page - 1) * 5)

  error_for_page_number(@categories_for_page, @page)
  @totals = @storage.category_totals(1)
  @budget = merge_budget_info(@budget, @totals)

  erb :budget, layout: :layout
end

# Display the page for changing the total and adding categories
get "/budget/edit" do
  @budget = load_budget(1)
  @categories = @storage.category_list(1)

  erb :edit_budget, layout: :layout
end

# Change the total budget amount
post "/budget/edit" do
  current_total = params[:current_total]
  new_total = params[:new_total]
  difference = (new_total.to_f - current_total.to_f)

  error = error_for_numeric_input(new_total)
  if error
    session[:error] = error
    erb :edit_budget, layout: :layout
  elsif difference > params[:uncategorized_funds].to_f
    session[:error] = error_for_new_budget_total
    erb :edit_budget, layout: :layout
  else
    @storage.update_budget(difference)
    redirect "/budget"
  end
end

# Create a new category for the current budget
post "/budget/edit/new_category" do
  name = params[:name]
  allocation = params[:allocation]
  source, source_funds = params[:source_id].split("|")

  @budget = load_budget(1)
  @categories = @storage.category_list(1)

  if (error = error_for_numeric_input(allocation))
    session[:error] = error
    params.delete(:allocation)
    erb :edit_budget, layout: :layout
  elsif (error = error_for_category_name(name, @categories))
    session[:error] = error
    params.delete(:name)
    erb :edit_budget, layout: :layout
  elsif source_funds.to_f < allocation.to_f
    session[:error] = error_insufficient_funds
    erb :edit_budget, layout: :layout
  else
    create_new_category(name, allocation, 1, source)
    redirect "/budget"
  end
end

# Display individual category's info page
get "/budget/categories/:category_id" do
  @page = params[:page] ? params[:page].to_i : 1
  category_id = params[:category_id]

  @category = load_category(category_id)
  @expenses = @storage.paginated_expenses(category_id, (@page - 1) * 5)
  error_for_page_number(@expenses, @page)

  erb :category, layout: :layout
end

# Display a category's "edit" page
get "/budget/categories/:category_id/edit" do
  @budget = load_budget(1)
  category_id = params[:category_id]
  @category = load_category(category_id)
  @other_categories = @storage.category_list(1).reject do |category|
    category[:id] == category_id
  end

  erb :edit_category, layout: :layout
end

# Update a category
post "/budget/categories/:category_id/edit" do
  category_id = params[:category_id]
  new_name = params[:new_name] == "" ? params[:current_name] : params[:new_name]
  current_allocation = params[:current_allocation]
  new_allocation = params[:new_allocation] == "" ? current_allocation : params[:new_allocation]
  source, source_funds = params[:source_id].split("|")
  difference = (new_allocation.to_f - current_allocation.to_f)

  @budget = load_budget(1)
  @category = load_category(category_id)
  @other_categories = @storage.category_list(1).reject do |category|
    category[:id] == category_id
  end

  if (input_error = error_for_numeric_input(new_allocation))
    session[:error] = input_error
    params.delete(:new_allocation)
    erb :edit_category, layout: :layout
  elsif (name_error = error_for_category_name(new_name, @other_categories))
    session[:error] = name_error
    params.delete(:new_name)
    erb :edit_category, layout: :layout
  elsif source_funds.to_f < difference
    session[:error] = error_insufficient_funds
    params.delete(:new_allocation)
    erb :edit_category, layout: :layout
  else
    @storage.update_category(category_id, new_name, new_allocation.to_f, source, difference)
    redirect "/budget/categories/#{category_id}"
  end
end

# Delete a category
post "/budget/categories/:category_id/delete" do
  id = params[:category_id]
  @storage.delete_category(id)

  redirect "/budget"
end

# Add a new expense to a category
post "/budget/categories/:category_id" do
  @page = params[:page] ? params[:page].to_i : 1
  category_id = params[:category_id]
  description = params[:description]
  amount = params[:amount].delete_prefix("$")
  date = params[:date]

  @category = load_category(category_id)
  @expenses = @storage.paginated_expenses(category_id, (@page - 1) * 5)

  if (error = error_for_numeric_input(amount))
    session[:error] = error
    params.delete(:amount)
    erb :category, layout: :layout
  elsif (error = error_for_description(description))
    session[:error] = error
    params.delete(:description)
    erb :category, layout: :layout
  else
    @storage.log_expense(category_id, description, amount, date)
    redirect "/budget/categories/#{category_id}"
  end
end

# Delete an expense
post "/budget/categories/:category_id/expenses/:expense_id/delete" do
  page = params[:page] ? params[:page].to_i : 1
  @storage.delete_expense(params[:expense_id])
  redirect "/budget/categories/#{params[:category_id]}?page=#{page}"
end

# Edit an individual expense
get "/budget/categories/:category_id/expenses/:expense_id/edit" do
  @page = params[:page] ? params[:page].to_i : 1
  category_id = params[:category_id]
  @category = load_category(category_id)
  @expenses = @storage.paginated_expenses(category_id, (@page - 1) * 5)
  error_for_page_number(@expenses, @page)
  @expense_id = params[:expense_id]
  validate_expense(@expense_id, @expenses)
  erb :edit_expense, layout: :layout
end

# Update an individual expense in the database
post "/budget/categories/:category_id/expenses/:expense_id/edit" do
  @page = params[:page] ? params[:page].to_i : 1
  category_id = params[:category_id]
  new_description = if params[:new_description].empty?
                      params[:current_description]
                    else
                      params[:new_description]
                    end
  new_amount = if params[:new_amount].empty?
                 params[:current_amount]
               else
                 params[:new_amount]
               end
  new_date = params[:new_date]

  @category = load_category(category_id)
  @expenses = @storage.paginated_expenses(category_id, (@page - 1) * 5)
  @expense_id = params[:expense_id]

  if (error = error_for_numeric_input(new_amount))
    session[:error] = error
    params.delete(:new_amount)
    erb :edit_expense, layout: :layout
  elsif (error = error_for_description(new_description))
    session[:error] = error
    params.delete(:new_description)
    erb :edit_expense, layout: :layout
  else
    @storage.update_expense(@expense_id, new_description, new_amount.to_f, new_date)
    redirect "/budget/categories/#{category_id}?page=#{@page}"
  end
end
