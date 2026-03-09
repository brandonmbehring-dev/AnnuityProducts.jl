"""
Dynamic Lapse Model for GLWB/GMWB products.

Implements moneyness-based lapse rates: higher ITM guarantees → lower lapse rates.

Theory
------
[T1] Base lapse rate adjusted by moneyness factor:
    lapse_rate(t) = base_lapse × f(moneyness)

where moneyness = GWB / AV (guarantee value / account value)
- moneyness < 1: OTM guarantee → higher lapse (rational)
- moneyness > 1: ITM guarantee → lower lapse (rational)
- moneyness = 1: ATM → base lapse

References:
- Bauer, Kling & Russ (2008), Section 4
- SOA 2006 Deferred Annuity Persistency Study
"""

"""
    LapseAssumptions

Lapse rate assumptions for dynamic lapse model.

# Fields
- `base_annual_lapse::Float64`: Base annual lapse rate (e.g., 0.05 for 5%)
- `min_lapse::Float64`: Floor on dynamic lapse rate
- `max_lapse::Float64`: Cap on dynamic lapse rate
- `sensitivity::Float64`: Sensitivity of lapse to moneyness (higher = more responsive)
- `surrender_period_reduction::Float64`: Reduction factor during surrender period
"""
struct LapseAssumptions
    base_annual_lapse::Float64
    min_lapse::Float64
    max_lapse::Float64
    sensitivity::Float64
    surrender_period_reduction::Float64

    function LapseAssumptions(;
        base_annual_lapse::Float64=0.05,
        min_lapse::Float64=0.01,
        max_lapse::Float64=0.25,
        sensitivity::Float64=1.0,
        surrender_period_reduction::Float64=0.2,
    )
        base_annual_lapse >= 0 || throw(ArgumentError("base_annual_lapse must be >= 0"))
        min_lapse >= 0 || throw(ArgumentError("min_lapse must be >= 0"))
        max_lapse >= min_lapse || throw(ArgumentError("max_lapse must be >= min_lapse"))
        sensitivity >= 0 || throw(ArgumentError("sensitivity must be >= 0"))
        0 <= surrender_period_reduction <= 1 ||
            throw(ArgumentError("surrender_period_reduction must be in [0, 1]"))

        new(
            base_annual_lapse, min_lapse, max_lapse, sensitivity, surrender_period_reduction
        )
    end
end

"""
    LapseResult

Result of lapse calculation with diagnostics.

# Fields
- `lapse_rate::Float64`: Calculated annual lapse rate
- `moneyness::Float64`: GWB/AV ratio used
- `adjustment_factor::Float64`: Multiplier applied to base lapse
"""
struct LapseResult
    lapse_rate::Float64
    moneyness::Float64
    adjustment_factor::Float64
end

"""
    DynamicLapseModel

Dynamic lapse model with moneyness adjustment.

[T1] Policyholders rationally lapse less when their guarantee is valuable (ITM).

# Example
```julia
model = DynamicLapseModel(LapseAssumptions())
result = calculate_lapse(model, gwb=110_000.0, av=100_000.0)  # ITM
result.lapse_rate < 0.05  # Lower than base
```
"""
struct DynamicLapseModel
    assumptions::LapseAssumptions
end

DynamicLapseModel() = DynamicLapseModel(LapseAssumptions())

"""
    calculate_lapse(model, gwb, av; surrender_period_complete=false) -> LapseResult

Calculate dynamic lapse rate.

[T1] lapse_rate = base_lapse × (AV/GWB)^sensitivity

When GWB > AV (ITM guarantee), AV/GWB < 1, so lapse rate decreases.
When GWB < AV (OTM guarantee), AV/GWB > 1, so lapse rate increases.

# Arguments
- `model::DynamicLapseModel`: Lapse model with assumptions
- `gwb::Float64`: Guaranteed Withdrawal Benefit value
- `av::Float64`: Current account value
- `surrender_period_complete::Bool=false`: Whether surrender period has ended

# Returns
- `LapseResult`: Calculated lapse rate with diagnostics
"""
function calculate_lapse(
    model::DynamicLapseModel,
    gwb::Float64,
    av::Float64;
    surrender_period_complete::Bool=false,
)
    assumptions = model.assumptions

    # Validate inputs
    av > 0 || throw(ArgumentError("Account value must be positive, got $av"))
    gwb >= 0 || throw(ArgumentError("GWB cannot be negative, got $gwb"))

    # Calculate moneyness = GWB / AV
    # Moneyness > 1: GWB exceeds AV (ITM guarantee) → lower lapse
    # Moneyness < 1: AV exceeds GWB (OTM guarantee) → higher lapse
    moneyness = gwb > 0 ? gwb / av : 1.0

    # Dynamic adjustment factor = (AV/GWB)^sensitivity = (1/moneyness)^sensitivity
    # When ITM (moneyness > 1): factor < 1 → lower lapse
    # When OTM (moneyness < 1): factor > 1 → higher lapse
    if gwb > 0
        adjustment_factor = (av / gwb) ^ assumptions.sensitivity
    else
        adjustment_factor = 1.0
    end

    # Base rate
    base_rate = assumptions.base_annual_lapse

    # If still in surrender period, reduce lapse significantly
    if !surrender_period_complete
        base_rate *= assumptions.surrender_period_reduction
    end

    # Apply dynamic adjustment
    lapse_rate = base_rate * adjustment_factor

    # Apply floor and cap
    lapse_rate = clamp(lapse_rate, assumptions.min_lapse, assumptions.max_lapse)

    return LapseResult(lapse_rate, moneyness, adjustment_factor)
end

"""
    calculate_monthly_lapse(model, gwb, av; surrender_period_complete=false) -> Float64

Calculate monthly lapse probability from annual rate.

[T1] monthly_lapse = 1 - (1 - annual_lapse)^(1/12)

# Returns
- `Float64`: Monthly lapse probability
"""
function calculate_monthly_lapse(
    model::DynamicLapseModel,
    gwb::Float64,
    av::Float64;
    surrender_period_complete::Bool=false,
)
    result = calculate_lapse(
        model, gwb, av; surrender_period_complete=surrender_period_complete
    )
    # Convert annual to monthly
    return 1.0 - (1.0 - result.lapse_rate) ^ (1.0 / 12.0)
end

"""
    calculate_path_lapses(model, gwb_path, av_path; surrender_period_ends=0) -> Vector{Float64}

Calculate lapse rates along a simulation path.

# Arguments
- `model::DynamicLapseModel`: Lapse model
- `gwb_path::Vector{Float64}`: Path of GWB values
- `av_path::Vector{Float64}`: Path of AV values
- `surrender_period_ends::Int=0`: Time step when surrender period ends (0 = already complete)

# Returns
- `Vector{Float64}`: Annual lapse rates at each time step
"""
function calculate_path_lapses(
    model::DynamicLapseModel,
    gwb_path::Vector{Float64},
    av_path::Vector{Float64};
    surrender_period_ends::Int=0,
)
    length(gwb_path) == length(av_path) || throw(
        ArgumentError(
            "Path lengths must match: gwb=$(length(gwb_path)), av=$(length(av_path))"
        ),
    )

    n_steps = length(gwb_path)
    lapse_rates = Vector{Float64}(undef, n_steps)

    for t in 1:n_steps
        surrender_complete = t > surrender_period_ends
        result = calculate_lapse(
            model, gwb_path[t], av_path[t]; surrender_period_complete=surrender_complete
        )
        lapse_rates[t] = result.lapse_rate
    end

    return lapse_rates
end

"""
    lapse_survival_probability(lapse_rates; dt=1.0) -> Vector{Float64}

Calculate cumulative survival (persistency) probability from lapse rates.

[T1] survival_t = ∏(1 - lapse_s × dt) for s in [1, t]

# Arguments
- `lapse_rates::Vector{Float64}`: Annual lapse rates at each time step
- `dt::Float64=1.0`: Time step size in years

# Returns
- `Vector{Float64}`: Cumulative survival probabilities (length = n_steps + 1)
  First element is 1.0 (survival at t=0)

# Note
Named `lapse_survival_probability` to distinguish from mortality-based survival.
"""
function lapse_survival_probability(lapse_rates::Vector{Float64}; dt::Float64=1.0)
    n_steps = length(lapse_rates)
    survival = Vector{Float64}(undef, n_steps + 1)
    survival[1] = 1.0  # Survival at t=0

    for t in 1:n_steps
        prob_stay = 1.0 - lapse_rates[t] * dt
        survival[t + 1] = survival[t] * max(prob_stay, 0.0)
    end

    return survival
end

"""
    apply_lapse_to_cashflows(cashflows, survival) -> Vector{Float64}

Weight cashflows by survival probability (lapse-adjusted expected value).

# Arguments
- `cashflows::Vector{Float64}`: Cashflows at each time step
- `survival::Vector{Float64}`: Survival probabilities (from `survival_probability`)

# Returns
- `Vector{Float64}`: Lapse-adjusted cashflows
"""
function apply_lapse_to_cashflows(cashflows::Vector{Float64}, survival::Vector{Float64})
    n = length(cashflows)
    # survival has n+1 elements (including t=0); use survival[2:end] for cashflows at t=1:n
    length(survival) >= n + 1 || throw(
        ArgumentError("Survival vector too short: need $(n+1), got $(length(survival))")
    )

    return cashflows .* survival[2:(n + 1)]
end

"""
    effective_lapse_rate(model, gwb_av_ratio; surrender_period_complete=false) -> Float64

Quick lookup: what lapse rate for a given moneyness ratio?

Useful for sensitivity analysis without full path simulation.

# Arguments
- `model::DynamicLapseModel`: Lapse model
- `gwb_av_ratio::Float64`: GWB/AV ratio (>1 = ITM, <1 = OTM)
- `surrender_period_complete::Bool=false`: Whether surrender period has ended

# Returns
- `Float64`: Annual lapse rate

# Example
```julia
model = DynamicLapseModel()
effective_lapse_rate(model, 1.2)  # 20% ITM → lower lapse
effective_lapse_rate(model, 0.8)  # 20% OTM → higher lapse
```
"""
function effective_lapse_rate(
    model::DynamicLapseModel, gwb_av_ratio::Float64; surrender_period_complete::Bool=false
)
    # Use gwb=ratio, av=1.0 to get effective rate
    result = calculate_lapse(
        model, gwb_av_ratio, 1.0; surrender_period_complete=surrender_period_complete
    )
    return result.lapse_rate
end
