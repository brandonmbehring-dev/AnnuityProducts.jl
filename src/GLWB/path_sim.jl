"""
Path simulation for GLWB pricing.

Simulates GLWB contract outcomes over multiple Monte Carlo paths.
"""

"""
    simulate_glwb(contract, monthly_returns; start_withdrawal_month=nothing, mortality_mode=:deterministic) -> Vector{GLWBResult}

Simulate GLWB contract over multiple paths.

# Arguments
- `contract::GLWBContract`: Contract parameters
- `monthly_returns::Matrix{Float64}`: Monthly returns, shape (n_paths, n_months)
- `start_withdrawal_month::Union{Int, Nothing}=nothing`: Month to start withdrawals
  (nothing = start after rollup period)
- `mortality_mode::Symbol=:deterministic`: `:deterministic` or `:stochastic`

# Returns
- `Vector{GLWBResult}`: Results for each path

# Notes
- Each row of monthly_returns is a separate path
- Mortality mode determines how survival is handled:
  - `:deterministic`: Apply survival probabilities to expected values
  - `:stochastic`: Random death time per path (future enhancement)
"""
function simulate_glwb(
    contract::GLWBContract,
    monthly_returns::Matrix{Float64};
    start_withdrawal_month::Union{Int,Nothing}=nothing,
    mortality_mode::Symbol=:deterministic,
)
    n_paths, n_months = size(monthly_returns)

    # Default: start withdrawals after rollup period
    withdrawal_start = something(start_withdrawal_month, contract.rollup_years * 12 + 1)

    results = Vector{GLWBResult}(undef, n_paths)

    for path_idx in 1:n_paths
        state = initial_state(contract)
        total_fees = 0.0
        total_withdrawals = 0.0
        months_in_payout = 0

        for month in 1:n_months
            take_withdrawal = month >= withdrawal_start

            withdrawal, fee = step_month!(
                state, contract, monthly_returns[path_idx, month], take_withdrawal
            )

            total_fees += fee
            total_withdrawals += withdrawal
            if take_withdrawal
                months_in_payout += 1
            end
        end

        results[path_idx] = GLWBResult(
            state.account_value,
            state.gwb,
            total_withdrawals,
            total_fees,
            months_in_payout,
            state.account_value <= 0.0,
        )
    end

    return results
end

"""
    simulate_single_path(contract, monthly_returns; start_withdrawal_month=nothing) -> GLWBResult

Simulate a single GLWB path.

Convenience function for single-path simulation.

# Arguments
- `contract::GLWBContract`: Contract parameters
- `monthly_returns::Vector{Float64}`: Monthly returns for this path
- `start_withdrawal_month::Union{Int, Nothing}=nothing`: Month to start withdrawals

# Returns
- `GLWBResult`: Result for this path
"""
function simulate_single_path(
    contract::GLWBContract,
    monthly_returns::Vector{Float64};
    start_withdrawal_month::Union{Int,Nothing}=nothing,
)
    # Convert to matrix with single row
    returns_matrix = reshape(monthly_returns, 1, :)
    results = simulate_glwb(
        contract, returns_matrix; start_withdrawal_month=start_withdrawal_month
    )
    return results[1]
end

"""
    calculate_glwb_value(contract, paths, discount_rate; kwargs...) -> NamedTuple

Calculate the present value of GLWB benefits and costs.

# Arguments
- `contract::GLWBContract`: Contract parameters
- `paths::Matrix{Float64}`: Monthly returns, shape (n_paths, n_months)
- `discount_rate::Float64`: Annual discount rate for PV calculations
- `kwargs...`: Passed to `simulate_glwb`

# Returns
Named tuple with:
- `pv_withdrawals::Float64`: PV of expected withdrawals
- `pv_fees::Float64`: PV of expected fees
- `net_cost::Float64`: pv_withdrawals - pv_fees (cost to insurer)
- `n_paths::Int`: Number of paths simulated
"""
function calculate_glwb_value(
    contract::GLWBContract, paths::Matrix{Float64}, discount_rate::Float64; kwargs...
)
    results = simulate_glwb(contract, paths; kwargs...)
    n_paths = length(results)
    n_months = size(paths, 2)

    # Monthly discount factor
    monthly_df = exp(-discount_rate / 12.0)

    # For simplified calculation, assume uniform timing
    # (More accurate would track month-by-month)
    avg_duration = n_months / 2.0  # Approximate
    avg_df = monthly_df^avg_duration

    pv_withdrawals = mean([r.total_withdrawals for r in results]) * avg_df
    pv_fees = mean([r.total_fees for r in results]) * avg_df

    return (
        pv_withdrawals=pv_withdrawals,
        pv_fees=pv_fees,
        net_cost=pv_withdrawals - pv_fees,
        n_paths=n_paths,
    )
end
