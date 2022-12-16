require "sinatra"
require "sinatra/content_for"
require "tilt/erubis"

require_relative "database_persistence"

configure do
  enable :sessions
  set :session_secret, "3619d4361dc051e2b3e889b4e873854348890d8dfa8efa4e8aa2657296948e6c" 
  # set :erb, :escape_html => true
end

configure(:development) do
  require "sinatra/reloader"
  also_reload "database_persistence.rb"
end

helpers do
  def format_currency(amount)
    "$" + format("%.2f", amount)
  end

  # would like to implement this to eventually have choice of output format
  def format_date(date, option)
  end

  def remaining_amount_class(amount)
    "red" if amount.to_f < 0
  end
end

# eventually this may need to incorporate user_id, to make sure that
# each user can only access budgets that belong to them
def load_budget(id)
  budget = @storage.budget_info(id)
  return budget if budget
  redirect("/new")
end

def load_category(id)
  p "id for load_category: #{id}"
  @storage.category_info(id)
end

def find_category_by_name(name, budget_id)
  id = @storage.get_category_id(name, budget_id)
  p id

  # TODO: handle nonexistent category
  unless id
    session[:error] = "Category not found."
    redirect "/budget"
  end
  id
end

def create_new_category(name, allocation, budget_id, source)
  if source == "uncategorized"
    @storage.pull_funds_from_uncategorized(budget_id, allocation)
  else
    @storage.pull_funds_from_category(source, allocation)
  end
  @storage.create_new_category(name, allocation, budget_id)
end

def total_spent_and_remaining(category_list)
  spent = (category_list.map { |category| category[:spent] }).sum
  remaining = (category_list.map { |category| category[:remaining] }).sum
  { spent: spent, remaining: remaining }
end

def error_for_numeric_input(value_string)
  unless value_string =~ /^[0-9]*($|\.[0-9]{1,2}$)/
    "Please enter a numeric value (dollars and cents) for the cost."
  end
end

def error_insufficient(source_funds, allocation)
  return unless source_funds < allocation
  puts "source_funds: #{source_funds}"
  puts "allocation: #{allocation}"
  <<~MESSAGE
      Oops, there aren't enough funds in the source you chose!\n
      You have a few options:\n
      1) Choose a different source,\n
      2) Allocate fewer funds, or\n
      3) Allocate fewer funds for now, and then add more later from a different source.
  MESSAGE
end

before do
  @storage = DatabasePersistence.new(logger)
end

after do
  @storage.disconnect
end

# Home page
get "/" do
  erb :home, layout: :layout
end

get "/new" do
end

post "/new" do
end

# Display budget overview page
get "/budget" do
  @budget_id = 1
  @budget = load_budget(@budget_id)
  @categories = @storage.all_categories(1)
  spent_and_remaining = total_spent_and_remaining(@categories)
  # calculating "remaining" using the sum of "spent" accounts for going "into the red" in individual categories
  remaining = @budget[:total].to_f  - spent_and_remaining[:spent].to_f
  spent_and_remaining[:remaining] = remaining.to_s
  @budget.merge!(spent_and_remaining)

  erb :budget, layout: :layout
end

# Create a new category for the current budget
post "/budget" do
  name = params[:name]
  allocation = params[:allocation]
  source = params[:source_id]
  budget_id = params[:budget_id]

  @budget_id = 1
  @budget = load_budget(@budget_id)
  @categories = @storage.all_categories(1)
  @budget.merge!(total_spent_and_remaining(@categories))

  error = error_for_numeric_input(allocation)
  if error
    session[:error] = error
    erb :budget, layout: :layout
  else
    source_funds = case source
                   when "uncategorized"
                     params[:uncategorized_funds].to_f
                   else
                     @storage.get_remaining_funds(source).to_f
                   end
    error = error_insufficient(source_funds, allocation.to_f)
    if error
      session[:error] = error
      erb :budget, layout: :layout
    else
      create_new_category(name, allocation, budget_id, source)
      redirect "/budget"
    end
  end
end

get "/budget/edit" do
  @budget_id = 1
  @budget = load_budget(@budget_id)

  erb :edit, layout: :layout
end

post "/budget/edit" do
end

# Delete a category
post "/budget/delete" do
  id = params[:category_id]
  @storage.delete_category(id)

  redirect "/budget"
end

# Display individual category's info page
get "/budget/:category" do
  if params[:category_id]
    category_id = params[:category_id]
    params.delete(:category_id)
  else
    category_id = find_category_by_name(params[:category], 1)
  end

  @category = load_category(category_id)
  # TODO make a method for this and handle bad input
  @expenses = @storage.category_expenses(category_id)

  erb :category, layout: :layout
end

# Add a new expense to a category
post "/budget/:category" do
  @category_id = params[:category_id]
  category_name = params[:category]
  description = params[:description]
  cost = params[:cost].delete_prefix("$")
  date = params[:date]
  # TODO
  p "@category_id: #{@category_id}"
  @category = @storage.category_info(@category_id)
  @expenses = @storage.category_expenses(@category_id)

  error = error_for_numeric_input(cost)
  if error
    session[:error] = error
    erb :category, layout: :layout
  else
    @storage.log_expense(@category_id, description, cost, date)
    redirect "/budget/#{category_name}"
  end
end

# Delete an expense
post "/budget/:category_name/delete" do
  @storage.delete_expense(params[:expense_id])
  redirect "/budget/#{params[:category_name]}"
end
