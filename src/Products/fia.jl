"""
FIA (Fixed Indexed Annuity) pricing.

FIAs provide returns linked to index performance with principal protection.

Theory
------
[T1] FIA = Bond + Call Option portfolio
     - Bond component provides principal protection (0% floor)
     - Option component provides index-linked upside

[T1] Option value decomposition:
     - Capped call = ATM call - OTM call at cap strike
     - Participation = par_rate × ATM call
     - Spread = Call at (1 + spread) strike

References:
- docs/knowledge/domain/crediting_methods.md
- CONSTITUTION.md Section 3.2
"""

using AnnuityCore:
    MonteCarloEngine,
    GBMParams,
    price_with_payoff,
    MCResult,
    CappedCallPayoff,
    ParticipationPayoff,
    SpreadPayoff,
    TriggerPayoff,
    black_scholes_call

"""
    FIAPricer

Pricer for Fixed Indexed Annuities.

# Fields
- `mc_engine::MonteCarloEngine`: Monte Carlo engine for option pricing
- `risk_free_rate::Float64`: Risk-free rate for discounting
- `dividend_yield::Float64`: Index dividend yield
- `volatility::Float64`: Index volatility
- `option_budget_pct::Float64`: Annual option budget as % of premium
"""
struct FIAPricer
    mc_engine::MonteCarloEngine
    risk_free_rate::Float64
    dividend_yield::Float64
    volatility::Float64
    option_budget_pct::Float64

    function FIAPricer(;
        n_paths::Int=100000,
        seed::Union{Int,Nothing}=42,
        risk_free_rate::Float64=0.04,
        dividend_yield::Float64=0.02,
        volatility::Float64=0.20,
        option_budget_pct::Float64=0.03,
    )
        risk_free_rate >= 0 || throw(ArgumentError("CRITICAL: risk_free_rate must be >= 0"))
        volatility >= 0 || throw(ArgumentError("CRITICAL: volatility must be >= 0"))
        option_budget_pct >= 0 ||
            throw(ArgumentError("CRITICAL: option_budget_pct must be >= 0"))

        engine = MonteCarloEngine(; n_paths=n_paths, seed=seed)
        new(engine, risk_free_rate, dividend_yield, volatility, option_budget_pct)
    end
end

"""
    FIAPriceResult

Result of FIA pricing.

# Fields
- `present_value::Float64`: Present value of FIA
- `embedded_option_value::Float64`: Value of embedded index option
- `option_budget::Float64`: Available option budget
- `expected_credit::Float64`: Expected credited return
- `fair_cap::Float64`: Fair cap rate given option budget
- `fair_participation::Float64`: Fair participation rate given option budget
- `crediting_method::Symbol`: Type of crediting method
- `term_years::Int`: Contract term
"""
struct FIAPriceResult
    present_value::Float64
    embedded_option_value::Float64
    option_budget::Float64
    expected_credit::Float64
    fair_cap::Float64
    fair_participation::Float64
    crediting_method::Symbol
    term_years::Int
end

"""
    price(pricer::FIAPricer, product; premium=100.0) -> FIAPriceResult

Price a FIA product.

[T1] FIA pricing:
     1. Calculate option budget from spread over risk-free
     2. Price embedded option via Monte Carlo
     3. Calculate fair cap/participation from budget
     4. Present value = PV(floor) + option value

# Arguments
- `pricer::FIAPricer`: The pricer configuration
- `product`: FIA product (from AnnuityData.jl)
- `premium::Float64=100.0`: Premium amount for scaling

# Returns
- `FIAPriceResult`: Pricing results
"""
function price(pricer::FIAPricer, product; premium::Float64=100.0)
    term_years = product.term_years
    term_years > 0 || throw(ArgumentError("CRITICAL: term_years must be > 0"))

    # Build GBM parameters (normalized to premium)
    params = GBMParams(
        premium,
        pricer.risk_free_rate,
        pricer.dividend_yield,
        pricer.volatility,
        Float64(term_years),
    )

    # Determine crediting method and build payoff
    payoff, method = build_fia_payoff(product)

    # Price the embedded option via Monte Carlo
    mc_result = price_with_payoff(pricer.mc_engine, params, payoff)

    # Option value as percentage of premium
    embedded_option_value = mc_result.price / premium

    # Calculate option budget using time value of money
    # [T1] Budget = pct × annuity factor where annuity factor = (1 - (1+r)^(-n))/r
    r = pricer.risk_free_rate
    if r > 1e-8
        annuity_factor = (1.0 - (1.0 + r)^(-term_years)) / r
    else
        annuity_factor = Float64(term_years)
    end
    option_budget = pricer.option_budget_pct * annuity_factor

    # Calculate expected credit from MC result
    expected_credit = mc_result.price / premium

    # Solve for fair cap and participation
    fair_cap = solve_fair_cap(pricer, Float64(term_years), option_budget, premium)
    fair_participation = solve_fair_participation(
        pricer, Float64(term_years), option_budget, premium
    )

    # Present value: PV of floor + option value
    # [T1] PV = discount × premium × (1 + expected_credit)
    discount_factor = exp(-pricer.risk_free_rate * term_years)
    present_value = discount_factor * premium * (1.0 + expected_credit)

    return FIAPriceResult(
        present_value,
        embedded_option_value,
        option_budget,
        expected_credit,
        fair_cap,
        fair_participation,
        method,
        term_years,
    )
end

"""
    build_fia_payoff(product) -> (AbstractPayoff, Symbol)

Build the appropriate payoff object for an FIA product.

Returns (payoff, crediting_method_symbol).
"""
function build_fia_payoff(product)
    # Determine crediting method based on which rate is set
    if product.cap_rate !== nothing && product.cap_rate > 0
        payoff = CappedCallPayoff(product.cap_rate, 0.0)
        return (payoff, :cap)
    elseif product.participation_rate !== nothing
        # Participation with optional cap
        cap = something(product.cap_rate, Inf)
        payoff = ParticipationPayoff(product.participation_rate, cap, 0.0)
        return (payoff, :participation)
    elseif product.spread_rate !== nothing
        payoff = SpreadPayoff(product.spread_rate, nothing, 0.0)
        return (payoff, :spread)
    else
        # [NEVER FAIL SILENTLY] No crediting method specified
        throw(
            ArgumentError(
                "CRITICAL: FIA product has no crediting method. " *
                "Expected cap_rate, participation_rate, or spread_rate.",
            ),
        )
    end
end

"""
    solve_fair_cap(pricer, term_years, option_budget, premium) -> Float64

Solve for fair cap rate given option budget.

[T1] Find cap such that capped_call_value = option_budget
     Uses bisection on cap rate.
"""
function solve_fair_cap(
    pricer::FIAPricer, term_years::Float64, option_budget::Float64, premium::Float64
)
    spot = premium  # Normalized
    r = pricer.risk_free_rate
    q = pricer.dividend_yield
    σ = pricer.volatility

    # ATM call value
    atm_call = black_scholes_call(spot, spot, r, q, σ, term_years)
    atm_call_pct = atm_call / spot

    # Budget as percentage
    budget_pct = option_budget

    # If budget >= ATM call, can offer unlimited cap
    if budget_pct >= atm_call_pct
        return 1.0  # 100% cap = effectively unlimited
    end

    # Bisection search for cap rate
    low, high = 0.01, 1.0
    target = budget_pct

    for _ in 1:50
        mid = (low + high) / 2
        cap_strike = spot * (1.0 + mid)

        otm_call = black_scholes_call(spot, cap_strike, r, q, σ, term_years)
        capped_value = (atm_call - otm_call) / spot

        if abs(capped_value - target) < 1e-6
            return mid
        elseif capped_value > target
            high = mid
        else
            low = mid
        end
    end

    return (low + high) / 2
end

"""
    solve_fair_participation(pricer, term_years, option_budget, premium) -> Float64

Solve for fair participation rate given option budget.

[T1] Participation = option_budget / ATM_call_value
"""
function solve_fair_participation(
    pricer::FIAPricer, term_years::Float64, option_budget::Float64, premium::Float64
)
    spot = premium
    r = pricer.risk_free_rate
    q = pricer.dividend_yield
    σ = pricer.volatility

    # ATM call value
    atm_call = black_scholes_call(spot, spot, r, q, σ, term_years)
    atm_call_pct = atm_call / spot

    if atm_call_pct < 1e-10
        return 0.0
    end

    # Participation = budget / ATM call
    return option_budget / atm_call_pct
end

"""
    calculate_option_budget(risk_free_rate, term_years; expense_rate=0.01) -> Float64

Calculate the option budget available for indexed crediting.

[T1] Option budget ≈ spread earned over term - expenses

This is the spread the insurer earns on investing premiums at risk-free
minus expenses.
"""
function calculate_option_budget(
    risk_free_rate::Float64, term_years::Float64; expense_rate::Float64=0.01
)
    # Spread earned over term (simple approximation)
    spread = 1.0 - exp(-risk_free_rate * term_years)

    # Less annual expenses
    annual_expense = expense_rate * term_years

    return max(0.0, spread - annual_expense)
end
