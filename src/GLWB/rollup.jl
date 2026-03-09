"""
Rollup benefit calculations for GLWB.

The rollup is a guaranteed minimum growth rate applied to the GWB
during the deferral (accumulation) phase.
"""

"""
    calculate_rollup_benefit(initial_premium, rollup_rate, years) -> Float64

Calculate the guaranteed withdrawal base after rollup period.

[T1] Simple rollup formula: GWB = P × (1 + r)^n
where:
- P = initial premium
- r = annual rollup rate
- n = number of years

# Arguments
- `initial_premium::Float64`: Initial premium amount
- `rollup_rate::Float64`: Annual rollup rate (decimal, e.g., 0.05 for 5%)
- `years::Int`: Number of years of rollup

# Returns
- `Float64`: Guaranteed withdrawal base after rollup

# Example
```julia
# \$100K premium, 5% rollup for 10 years
gwb = calculate_rollup_benefit(100000.0, 0.05, 10)
# => 162889.46 (100000 × 1.05^10)
```
"""
function calculate_rollup_benefit(
    initial_premium::Float64, rollup_rate::Float64, years::Int
)
    initial_premium > 0 || throw(ArgumentError("CRITICAL: initial_premium must be > 0"))
    rollup_rate >= 0 || throw(ArgumentError("CRITICAL: rollup_rate must be >= 0"))
    years >= 0 || throw(ArgumentError("CRITICAL: years must be >= 0"))

    return initial_premium * (1.0 + rollup_rate)^years
end

"""
    calculate_monthly_rollup_benefit(initial_premium, annual_rollup_rate, months) -> Float64

Calculate the guaranteed withdrawal base using monthly compounding.

[T1] Monthly rollup formula: GWB = P × (1 + r/12)^m
where:
- P = initial premium
- r = annual rollup rate
- m = number of months

# Arguments
- `initial_premium::Float64`: Initial premium amount
- `annual_rollup_rate::Float64`: Annual rollup rate (decimal)
- `months::Int`: Number of months of rollup

# Returns
- `Float64`: Guaranteed withdrawal base after monthly rollup
"""
function calculate_monthly_rollup_benefit(
    initial_premium::Float64, annual_rollup_rate::Float64, months::Int
)
    initial_premium > 0 || throw(ArgumentError("CRITICAL: initial_premium must be > 0"))
    annual_rollup_rate >= 0 ||
        throw(ArgumentError("CRITICAL: annual_rollup_rate must be >= 0"))
    months >= 0 || throw(ArgumentError("CRITICAL: months must be >= 0"))

    monthly_rate = annual_rollup_rate / 12.0
    return initial_premium * (1.0 + monthly_rate)^months
end

"""
    calculate_annual_withdrawal(gwb, withdrawal_rate) -> Float64

Calculate the annual guaranteed withdrawal amount.

# Arguments
- `gwb::Float64`: Guaranteed withdrawal base
- `withdrawal_rate::Float64`: Annual withdrawal rate (decimal, e.g., 0.05 for 5%)

# Returns
- `Float64`: Annual withdrawal amount
"""
function calculate_annual_withdrawal(gwb::Float64, withdrawal_rate::Float64)
    gwb >= 0 || throw(ArgumentError("CRITICAL: gwb must be >= 0"))
    withdrawal_rate >= 0 || throw(ArgumentError("CRITICAL: withdrawal_rate must be >= 0"))

    return gwb * withdrawal_rate
end
