"""
Mortality table integration via MortalityTables.jl.

Provides access to SOA mortality tables for actuarial calculations.
"""

using MortalityTables: get_SOA_table, UltimateTable, SelectUltimateTable

# Common SOA table names (with exact characters)
const COMMON_TABLES = Dict{Symbol,String}(
    :IAM_2012_Male => "2012 IAM Period Table – Male, ANB",
    :IAM_2012_Female => "2012 IAM Period Table – Female, ANB",
    :CSO_2017_Male => "2017 Loaded CSO Preferred Structure ALB – Male, ANB",
    :CSO_2017_Female => "2017 Loaded CSO Preferred Structure ALB – Female, ANB",
)

"""
    load_mortality_table(table_name::Union{String, Symbol}) -> MortalityTable

Load a mortality table by name.

# Arguments
- `table_name::Union{String, Symbol}`: SOA table name or symbol shortcut

# Available Shortcuts
- `:IAM_2012_Male` - 2012 IAM Period Male
- `:IAM_2012_Female` - 2012 IAM Period Female
- `:CSO_2017_Male` - 2017 CSO Male
- `:CSO_2017_Female` - 2017 CSO Female

# Example
```julia
table = load_mortality_table(:IAM_2012_Male)
qx = get_qx(table, 65)  # Mortality rate at age 65
```
"""
function load_mortality_table(table_name::Symbol)
    if haskey(COMMON_TABLES, table_name)
        return get_SOA_table(COMMON_TABLES[table_name])
    else
        error(
            "CRITICAL: Unknown table shortcut '$table_name'. " *
            "Available: $(keys(COMMON_TABLES))",
        )
    end
end

function load_mortality_table(table_name::String)
    try
        return get_SOA_table(table_name)
    catch e
        error("CRITICAL: Failed to load mortality table '$table_name'. Error: $e")
    end
end

"""
    get_qx(table, age::Int) -> Float64

Get mortality rate qx at a given age.

# Arguments
- `table`: Mortality table (from load_mortality_table)
- `age::Int`: Age

# Returns
- `Float64`: Annual mortality rate
"""
function get_qx(table, age::Int)
    age >= 0 || throw(ArgumentError("CRITICAL: age must be >= 0"))

    # MortalityTables.jl UltimateTable has .ultimate field
    if table isa UltimateTable
        return table.ultimate[age]
    elseif table isa SelectUltimateTable
        return table.ultimate[age]
    elseif hasfield(typeof(table), :ultimate)
        return table.ultimate[age]
    else
        error("CRITICAL: Unknown table type $(typeof(table))")
    end
end

"""
    survival_probability(table, age::Int, years::Int) -> Float64

Calculate probability of surviving from current age for given years.

[T1] Survival probability: ₜpₓ = ∏ᵢ₌₀ᵗ⁻¹ (1 - qₓ₊ᵢ)

# Arguments
- `table`: Mortality table
- `age::Int`: Current age
- `years::Int`: Number of years to survive

# Returns
- `Float64`: Probability of surviving (between 0 and 1)

# Example
```julia
table = load_mortality_table(:IAM_2012_Male)
p = survival_probability(table, 65, 10)  # P(survive 10 years from age 65)
```
"""
function survival_probability(table, age::Int, years::Int)
    age >= 0 || throw(ArgumentError("CRITICAL: age must be >= 0"))
    years >= 0 || throw(ArgumentError("CRITICAL: years must be >= 0"))

    if years == 0
        return 1.0
    end

    prob = 1.0
    for i in 0:(years - 1)
        qx = get_qx(table, age + i)
        prob *= (1.0 - qx)
        if prob <= 0.0
            return 0.0  # Died
        end
    end
    return prob
end

"""
    calc_life_expectancy(table, age::Int; max_age::Int=120) -> Float64

Calculate remaining life expectancy at given age.

[T1] Complete expectation of life: eₓ = Σₜ ₜpₓ

# Arguments
- `table`: Mortality table
- `age::Int`: Current age
- `max_age::Int=120`: Maximum age for calculation

# Returns
- `Float64`: Expected remaining years of life

# Note
Named `calc_life_expectancy` to avoid conflict with MortalityTables.life_expectancy.
"""
function calc_life_expectancy(table, age::Int; max_age::Int=120)
    age >= 0 || throw(ArgumentError("CRITICAL: age must be >= 0"))
    age < max_age || throw(ArgumentError("CRITICAL: age must be < max_age"))

    expectation = 0.0
    for t in 1:(max_age - age)
        t_px = survival_probability(table, age, t)
        expectation += t_px
    end
    return expectation
end

"""
    annuity_factor(table, age::Int, rate::Float64; term::Union{Int, Nothing}=nothing, max_age::Int=120) -> Float64

Calculate present value of life annuity (äₓ).

[T1] Life annuity: äₓ = Σₜ vᵗ × ₜpₓ
where v = 1/(1+i) is the discount factor.

# Arguments
- `table`: Mortality table
- `age::Int`: Annuitant age
- `rate::Float64`: Discount rate
- `term::Union{Int, Nothing}=nothing`: Term limit (nothing = whole life)
- `max_age::Int=120`: Maximum age for whole life calculation

# Returns
- `Float64`: Present value of 1 dollar annual annuity

# Example
```julia
table = load_mortality_table(:IAM_2012_Male)
a_65 = annuity_factor(table, 65, 0.05)  # Whole life annuity at 65
a_65_10 = annuity_factor(table, 65, 0.05; term=10)  # 10-year term
```
"""
function annuity_factor(
    table, age::Int, rate::Float64; term::Union{Int,Nothing}=nothing, max_age::Int=120
)
    age >= 0 || throw(ArgumentError("CRITICAL: age must be >= 0"))
    rate >= 0 || throw(ArgumentError("CRITICAL: rate must be >= 0"))

    v = 1.0 / (1.0 + rate)  # Discount factor
    n_periods = term !== nothing ? term : (max_age - age)

    annuity_pv = 0.0
    for t in 1:n_periods
        t_px = survival_probability(table, age, t)
        annuity_pv += (v^t) * t_px
    end
    return annuity_pv
end

"""
    list_available_tables() -> Vector{Symbol}

List available mortality table shortcuts.

# Returns
- `Vector{Symbol}`: List of available table shortcuts

# Example
```julia
tables = list_available_tables()
# [:IAM_2012_Male, :IAM_2012_Female, :CSO_2017_Male, :CSO_2017_Female]
```
"""
function list_available_tables()
    return collect(keys(COMMON_TABLES))
end
