"""
GLWB Path-Dependent Monte Carlo Pricer.

Prices GLWB guarantees using path-dependent Monte Carlo simulation.

Theory
------
[T1] GLWB value = E[PV(insurer payments when AV exhausted)]

The insurer pays when:
1. Account value is exhausted (AV = 0)
2. Policyholder is still alive
3. Guaranteed withdrawals continue until death

References:
- Bauer, Kling & Russ (2008) "A Universal Pricing Framework"
"""

using StableRNGs
using Statistics: mean, std

"""
    GLWBPricingConfig

Configuration for GLWB pricing simulation.

# Fields
- `premium::Float64`: Initial premium
- `age::Int`: Current age
- `r::Float64`: Risk-free rate (annual)
- `sigma::Float64`: Volatility (annual)
- `max_age::Int`: Maximum simulation age
- `rollup_type::Symbol`: `:compound` or `:simple`
- `rollup_rate::Float64`: Annual rollup rate
- `rollup_cap_years::Int`: Maximum years rollup applies
- `withdrawal_rate::Float64`: Annual withdrawal rate as % of GWB
- `fee_rate::Float64`: Annual fee rate
- `steps_per_year::Int`: Timesteps per year (1=annual, 12=monthly)
- `n_paths::Int`: Number of Monte Carlo paths
- `seed::Union{Int, Nothing}`: Random seed (nothing for random)
"""
struct GLWBPricingConfig
    premium::Float64
    age::Int
    r::Float64
    sigma::Float64
    max_age::Int
    rollup_type::Symbol
    rollup_rate::Float64
    rollup_cap_years::Int
    withdrawal_rate::Float64
    fee_rate::Float64
    steps_per_year::Int
    n_paths::Int
    seed::Union{Int,Nothing}

    function GLWBPricingConfig(;
        premium::Float64,
        age::Int,
        r::Float64,
        sigma::Float64,
        max_age::Int=100,
        rollup_type::Symbol=:compound,
        rollup_rate::Float64=0.05,
        rollup_cap_years::Int=10,
        withdrawal_rate::Float64=0.05,
        fee_rate::Float64=0.01,
        steps_per_year::Int=1,
        n_paths::Int=1000,
        seed::Union{Int,Nothing}=nothing,
    )
        premium > 0 || throw(ArgumentError("CRITICAL: premium must be > 0"))
        age >= 0 || throw(ArgumentError("CRITICAL: age must be >= 0"))
        age < max_age || throw(ArgumentError("CRITICAL: age must be < max_age"))
        sigma >= 0 || throw(ArgumentError("CRITICAL: sigma must be >= 0"))
        steps_per_year >= 1 || throw(ArgumentError("CRITICAL: steps_per_year must be >= 1"))
        n_paths >= 1 || throw(ArgumentError("CRITICAL: n_paths must be >= 1"))
        rollup_type in (:compound, :simple) ||
            throw(ArgumentError("CRITICAL: rollup_type must be :compound or :simple"))

        new(
            premium,
            age,
            r,
            sigma,
            max_age,
            rollup_type,
            rollup_rate,
            rollup_cap_years,
            withdrawal_rate,
            fee_rate,
            steps_per_year,
            n_paths,
            seed,
        )
    end
end

"""
    GLWBPricingResult

Result of GLWB pricing simulation.

# Fields
- `price::Float64`: Risk-neutral price of GLWB guarantee
- `guarantee_cost::Float64`: Cost of guarantee as fraction of premium
- `mean_payoff::Float64`: Average discounted payoff
- `std_payoff::Float64`: Standard deviation of discounted payoff
- `standard_error::Float64`: Standard error of mean
- `prob_ruin::Float64`: Probability AV exhausted before death
- `mean_ruin_year::Float64`: Average year of ruin (if ruin occurs), -1 if no ruin
- `prob_lapse::Float64`: Probability of lapse (0 in simplified mode)
- `mean_lapse_year::Float64`: Average year of lapse (-1 if no lapse)
"""
struct GLWBPricingResult
    price::Float64
    guarantee_cost::Float64
    mean_payoff::Float64
    std_payoff::Float64
    standard_error::Float64
    prob_ruin::Float64
    mean_ruin_year::Float64
    prob_lapse::Float64
    mean_lapse_year::Float64
end

"""
    SinglePathResult

Result of a single path simulation (internal).
"""
struct SinglePathResult
    pv_insurer_payments::Float64
    ruin_year::Int  # -1 if no ruin
    death_year::Int  # -1 if survived
    final_av::Float64
    final_gwb::Float64
end

# ============================================================================
# Mortality Tables (Simplified SOA 2012 IAM approximation)
# ============================================================================

"""
    soa_2012_iam_qx(age::Int) -> Float64

Simplified SOA 2012 IAM male mortality rates.

[T2] Approximation based on Gompertz-Makeham model fit to SOA 2012 IAM.
For production, use actual table from MortalityTables.jl.

# Arguments
- `age::Int`: Current age

# Returns
- `Float64`: Annual mortality rate qx
"""
function soa_2012_iam_qx(age::Int)
    # Gompertz-Makeham approximation for SOA 2012 IAM Male
    # qx ≈ A + B * exp(C * age)
    # Parameters fit to approximate SOA 2012 IAM Period Male
    A = 0.0001  # Accident/non-age-related mortality
    B = 0.00003
    C = 0.085

    qx = A + B * exp(C * age)
    return min(qx, 1.0)  # Cap at 1.0
end

# ============================================================================
# Path Simulation
# ============================================================================

"""
    simulate_single_glwb_path(config, rng) -> SinglePathResult

Simulate a single GLWB path using Monte Carlo.

[T1] Under risk-neutral measure: drift = r - 0.5*sigma^2

# Arguments
- `config::GLWBPricingConfig`: Pricing configuration
- `rng::AbstractRNG`: Random number generator

# Returns
- `SinglePathResult`: Path simulation result
"""
function simulate_single_glwb_path(config::GLWBPricingConfig, rng::AbstractRNG)
    # Timestep parameters
    dt = 1.0 / config.steps_per_year
    n_years = config.max_age - config.age
    n_steps = n_years * config.steps_per_year

    # GBM parameters scaled to timestep
    drift_per_step = (config.r - 0.5 * config.sigma^2) * dt
    diffusion_per_step = config.sigma * sqrt(dt)

    # Initialize state
    av = config.premium  # Account value
    gwb = config.premium  # Guaranteed withdrawal base
    current_age = config.age

    # Tracking variables
    pv_insurer_payments = 0.0
    ruin_year = -1
    death_year = -1

    # Withdrawal parameters
    max_withdrawal_annual = gwb * config.withdrawal_rate  # Will update with GWB

    # Initialize mortality (will be updated at year boundaries)
    qx_annual = soa_2012_iam_qx(current_age)
    qx_step = 1.0 - (1.0 - qx_annual)^dt

    for step in 1:n_steps
        # Current time in years
        t_years = step * dt

        # Update mortality at year boundaries
        if step > 1 && ((step - 1) % config.steps_per_year == 0)
            qx_annual = soa_2012_iam_qx(current_age)
            qx_step = 1.0 - (1.0 - qx_annual)^dt
        end

        if rand(rng) < qx_step
            death_year = Int(ceil(t_years))
            break
        end

        # Generate return (risk-neutral GBM)
        z = randn(rng)
        av_return = drift_per_step + diffusion_per_step * z

        # Apply return to AV
        av = av * (1.0 + av_return)
        av = max(0.0, av)

        # Charge fee
        fee = av * config.fee_rate * dt
        av = max(0.0, av - fee)

        # Apply rollup to GWB (during rollup period only)
        if t_years <= config.rollup_cap_years
            if config.rollup_type == :compound
                rollup_per_step = (1.0 + config.rollup_rate)^dt - 1.0
            else  # simple
                rollup_per_step = config.rollup_rate * dt
            end
            gwb = gwb * (1.0 + rollup_per_step)
        end

        # Calculate withdrawal
        max_withdrawal_step = gwb * config.withdrawal_rate * dt
        withdrawal = max_withdrawal_step  # 100% utilization

        # Withdraw from AV
        actual_from_av = min(withdrawal, av)
        av = max(0.0, av - actual_from_av)

        # Discount factor
        df = exp(-config.r * t_years)

        # Check for ruin (AV exhausted)
        if av <= 0.0 && ruin_year < 0
            ruin_year = Int(ceil(t_years))
        end

        # If ruined, insurer pays guaranteed amount
        if av <= 0.0
            insurer_payment = max_withdrawal_step
            pv_insurer_payments += insurer_payment * df
        end

        # Update age at year boundaries
        if step % config.steps_per_year == 0
            current_age += 1
        end
    end

    return SinglePathResult(pv_insurer_payments, ruin_year, death_year, av, gwb)
end

"""
    price_glwb(config::GLWBPricingConfig) -> GLWBPricingResult

Price a GLWB guarantee using path-dependent Monte Carlo.

[T1] Price = E[PV(insurer payments when AV = 0)]

# Arguments
- `config::GLWBPricingConfig`: Pricing configuration

# Returns
- `GLWBPricingResult`: Pricing result with diagnostics
"""
function price_glwb(config::GLWBPricingConfig)
    # Initialize RNG
    rng = isnothing(config.seed) ? StableRNG(rand(UInt64)) : StableRNG(config.seed)

    # Simulate paths
    pv_payoffs = Vector{Float64}(undef, config.n_paths)
    ruin_years = Int[]

    for i in 1:config.n_paths
        result = simulate_single_glwb_path(config, rng)
        pv_payoffs[i] = result.pv_insurer_payments

        if result.ruin_year >= 0
            push!(ruin_years, result.ruin_year)
        end
    end

    # Aggregate results
    mean_payoff = mean(pv_payoffs)
    std_payoff = std(pv_payoffs)
    standard_error = std_payoff / sqrt(config.n_paths)

    prob_ruin = length(ruin_years) / config.n_paths
    mean_ruin_year = isempty(ruin_years) ? -1.0 : mean(ruin_years)

    # No lapse in simplified mode
    prob_lapse = 0.0
    mean_lapse_year = -1.0

    return GLWBPricingResult(
        mean_payoff,                    # price
        mean_payoff / config.premium,   # guarantee_cost
        mean_payoff,                    # mean_payoff
        std_payoff,                     # std_payoff
        standard_error,                 # standard_error
        prob_ruin,                      # prob_ruin
        mean_ruin_year,                 # mean_ruin_year
        prob_lapse,                     # prob_lapse
        mean_lapse_year,                 # mean_lapse_year
    )
end

"""
    price_glwb(;kwargs...) -> GLWBPricingResult

Price GLWB with keyword arguments (convenience method).

# Keyword Arguments
All parameters from GLWBPricingConfig.

# Example
```julia
result = price_glwb(
    premium = 100000.0,
    age = 65,
    r = 0.04,
    sigma = 0.20,
    rollup_rate = 0.05,
    withdrawal_rate = 0.05,
    n_paths = 1000,
    seed = 42
)
```
"""
function price_glwb(; kwargs...)
    config = GLWBPricingConfig(; kwargs...)
    return price_glwb(config)
end
