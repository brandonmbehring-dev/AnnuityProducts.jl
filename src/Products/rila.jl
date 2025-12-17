"""
RILA (Registered Index-Linked Annuity) pricing.

RILAs provide market exposure with downside protection via buffers or floors.

Theory
------
[T1] RILAs can have negative returns (unlike FIA with 0% floor).
[T1] Buffer = Long ATM put - Short OTM put (put spread)
[T1] Floor = Long OTM put

References:
- docs/knowledge/domain/buffer_floor.md
- CONSTITUTION.md Section 3.2
"""

using AnnuityCore: MonteCarloEngine, GBMParams, price_with_payoff, MCResult,
                   BufferPayoff, FloorPayoff, black_scholes_call, black_scholes_put


"""
    RILAPricer

Pricer for Registered Index-Linked Annuities.

# Fields
- `mc_engine::MonteCarloEngine`: Monte Carlo engine for option pricing
- `risk_free_rate::Float64`: Risk-free rate for discounting
- `dividend_yield::Float64`: Index dividend yield
- `volatility::Float64`: Index volatility
"""
struct RILAPricer
    mc_engine::MonteCarloEngine
    risk_free_rate::Float64
    dividend_yield::Float64
    volatility::Float64

    function RILAPricer(;
        n_paths::Int = 100000,
        seed::Union{Int, Nothing} = 42,
        risk_free_rate::Float64 = 0.04,
        dividend_yield::Float64 = 0.02,
        volatility::Float64 = 0.20
    )
        risk_free_rate >= 0 || throw(ArgumentError("CRITICAL: risk_free_rate must be >= 0"))
        volatility >= 0 || throw(ArgumentError("CRITICAL: volatility must be >= 0"))

        engine = MonteCarloEngine(n_paths=n_paths, seed=seed)
        new(engine, risk_free_rate, dividend_yield, volatility)
    end
end


"""
    RILAPriceResult

Result of RILA pricing.

# Fields
- `present_value::Float64`: Present value of RILA
- `protection_value::Float64`: Value of buffer/floor protection to policyholder
- `protection_type::Symbol`: `:buffer` or `:floor`
- `upside_value::Float64`: Value of capped upside
- `expected_return::Float64`: Expected return from MC simulation
- `max_loss::Float64`: Maximum possible loss
- `breakeven_return::Float64`: Index return needed to break even
- `fair_cap::Float64`: Fair cap given protection level
- `term_years::Int`: Contract term
"""
struct RILAPriceResult
    present_value::Float64
    protection_value::Float64
    protection_type::Symbol
    upside_value::Float64
    expected_return::Float64
    max_loss::Float64
    breakeven_return::Float64
    fair_cap::Float64
    term_years::Int
end


"""
    price(pricer::RILAPricer, product; premium=100.0) -> RILAPriceResult

Price a RILA product.

[T1] RILA pricing:
     1. Price protection component (put spread for buffer, OTM put for floor)
     2. Price upside component (capped call)
     3. Calculate expected return via Monte Carlo
     4. PV = discount × premium × (1 + expected_return)

# Arguments
- `pricer::RILAPricer`: The pricer configuration
- `product`: RILA product (from AnnuityData.jl)
- `premium::Float64=100.0`: Premium amount for scaling

# Returns
- `RILAPriceResult`: Pricing results
"""
function price(pricer::RILAPricer, product; premium::Float64 = 100.0)
    term_years = product.term_years
    term_years > 0 || throw(ArgumentError("CRITICAL: term_years must be > 0"))

    # Determine protection type
    protection_type = product.protection_type
    protection_type in (:buffer, :floor) || throw(ArgumentError(
        "CRITICAL: protection_type must be :buffer or :floor, got $protection_type"
    ))

    is_buffer = protection_type == :buffer

    # Get protection and cap rates
    buffer_rate = product.buffer_rate
    buffer_rate > 0 || throw(ArgumentError("CRITICAL: buffer_rate must be > 0"))

    cap_rate = product.cap_rate

    # Calculate max loss
    max_loss = is_buffer ? (1.0 - buffer_rate) : buffer_rate

    # Build GBM parameters
    params = GBMParams(
        premium,  # Normalized to premium
        pricer.risk_free_rate,
        pricer.dividend_yield,
        pricer.volatility,
        Float64(term_years)
    )

    # Price protection component
    protection_value = price_protection(
        pricer, is_buffer, buffer_rate, Float64(term_years), premium
    )

    # Price upside component
    upside_value = price_upside(
        pricer, cap_rate, Float64(term_years), premium
    )

    # Calculate expected return via MC
    expected_return = calculate_expected_return(
        pricer, is_buffer, buffer_rate, cap_rate, Float64(term_years)
    )

    # Calculate breakeven return
    breakeven_return = calculate_breakeven(is_buffer, buffer_rate)

    # Calculate fair cap
    fair_cap = calculate_fair_cap(pricer, buffer_rate, Float64(term_years))

    # Present value
    discount_factor = exp(-pricer.risk_free_rate * term_years)
    present_value = discount_factor * premium * (1.0 + expected_return)

    return RILAPriceResult(
        present_value,
        protection_value,
        protection_type,
        upside_value,
        expected_return,
        max_loss,
        breakeven_return,
        fair_cap,
        term_years
    )
end


"""
    price_protection(pricer, is_buffer, buffer_rate, term_years, premium) -> Float64

Price the downside protection component.

[T1] Buffer = Long ATM put - Short OTM put (put spread)
[T1] Floor = Long OTM put
[T1] 100% buffer edge case: full ATM put protection (OTM strike would be 0)
"""
function price_protection(
    pricer::RILAPricer,
    is_buffer::Bool,
    buffer_rate::Float64,
    term_years::Float64,
    premium::Float64
)
    spot = premium
    r = pricer.risk_free_rate
    q = pricer.dividend_yield
    σ = pricer.volatility

    if is_buffer
        # [T1] 100% buffer edge case
        if buffer_rate >= 1.0 - 1e-10
            atm_put = black_scholes_put(spot, spot, r, q, σ, term_years)
            protection = atm_put
        else
            # Buffer = Long ATM put - Short OTM put
            atm_put = black_scholes_put(spot, spot, r, q, σ, term_years)
            otm_strike = spot * (1.0 - buffer_rate)
            otm_put = black_scholes_put(spot, otm_strike, r, q, σ, term_years)
            protection = atm_put - otm_put
        end
    else
        # Floor = Long OTM put at floor strike
        floor_strike = spot * (1.0 - buffer_rate)
        protection = black_scholes_put(spot, floor_strike, r, q, σ, term_years)
    end

    return protection / spot * premium
end


"""
    price_upside(pricer, cap_rate, term_years, premium) -> Float64

Price the capped upside component.

[T1] Capped call = ATM call - OTM call at cap strike
"""
function price_upside(
    pricer::RILAPricer,
    cap_rate::Union{Float64, Nothing},
    term_years::Float64,
    premium::Float64
)
    spot = premium
    r = pricer.risk_free_rate
    q = pricer.dividend_yield
    σ = pricer.volatility

    # ATM call for full upside
    atm_call = black_scholes_call(spot, spot, r, q, σ, term_years)

    if cap_rate !== nothing && cap_rate > 0
        # Capped call = ATM call - OTM call at cap
        cap_strike = spot * (1.0 + cap_rate)
        otm_call = black_scholes_call(spot, cap_strike, r, q, σ, term_years)
        upside = atm_call - otm_call
    else
        # Uncapped
        upside = atm_call
    end

    return upside / spot * premium
end


"""
    calculate_expected_return(pricer, is_buffer, buffer_rate, cap_rate, term_years) -> Float64

Calculate expected return via Monte Carlo simulation.
"""
function calculate_expected_return(
    pricer::RILAPricer,
    is_buffer::Bool,
    buffer_rate::Float64,
    cap_rate::Union{Float64, Nothing},
    term_years::Float64
)
    params = GBMParams(
        100.0,  # Normalized spot
        pricer.risk_free_rate,
        pricer.dividend_yield,
        pricer.volatility,
        term_years
    )

    # Create appropriate payoff
    # BufferPayoff(buffer_rate, cap_rate) - 2 arguments
    # FloorPayoff(floor_rate, cap_rate) - 2 arguments, floor_rate is negative
    if is_buffer
        payoff = BufferPayoff(buffer_rate, cap_rate)
    else
        # Floor payoff (floor_rate is negative for FloorPayoff semantics)
        payoff = FloorPayoff(-buffer_rate, cap_rate)
    end

    # Price via MC
    mc_result = price_with_payoff(pricer.mc_engine, params, payoff)

    # Convert to return
    return mc_result.price / 100.0
end


"""
    calculate_breakeven(is_buffer, buffer_rate) -> Float64

Calculate breakeven index return.

[T1] Buffer: breakeven = -buffer_rate (buffer fully absorbs loss)
[T1] Floor: breakeven = 0 (any negative return = loss)
"""
function calculate_breakeven(is_buffer::Bool, buffer_rate::Float64)
    if is_buffer
        return -buffer_rate
    else
        return 0.0
    end
end


"""
    calculate_fair_cap(pricer, buffer_rate, term_years) -> Float64

Calculate the fair cap rate given a buffer level.

The fair cap makes the structure cost-neutral: value of buffer protection
equals value of cap forgone.

Uses bisection search to find cap where PV with protection equals market PV.
"""
function calculate_fair_cap(
    pricer::RILAPricer,
    buffer_rate::Float64,
    term_years::Float64
)
    spot = 100.0
    r = pricer.risk_free_rate
    q = pricer.dividend_yield
    σ = pricer.volatility

    # Value of buffer protection (normalized by spot)
    if buffer_rate >= 1.0 - 1e-10
        # 100% buffer: full ATM put
        atm_put = black_scholes_put(spot, spot, r, q, σ, term_years)
        protection_value = atm_put / spot
    else
        atm_put = black_scholes_put(spot, spot, r, q, σ, term_years)
        otm_strike = spot * (1.0 - buffer_rate)
        otm_put = black_scholes_put(spot, otm_strike, r, q, σ, term_years)
        protection_value = (atm_put - otm_put) / spot
    end

    # ATM call value (normalized)
    atm_call = black_scholes_call(spot, spot, r, q, σ, term_years) / spot

    # Find cap where (ATM call - OTM call)/spot = protection_value
    # This makes the structure cost-neutral

    # Bisection search with wider range
    low, high = 0.01, 2.0  # 1% to 200% cap range

    for _ in 1:100  # More iterations for better convergence
        mid = (low + high) / 2.0
        cap_strike = spot * (1.0 + mid)
        otm_call = black_scholes_call(spot, cap_strike, r, q, σ, term_years) / spot
        cap_cost = atm_call - otm_call

        diff = cap_cost - protection_value

        if abs(diff) < 0.0001  # Tighter tolerance
            return mid
        elseif diff > 0
            # Cap cost too high, need higher cap (less forgone upside)
            low = mid
        else
            # Cap cost too low, need lower cap
            high = mid
        end
    end

    return (low + high) / 2.0
end


"""
    compare_buffer_vs_floor(pricer, buffer_rate, floor_rate, cap_rate, term_years)

Compare buffer vs floor protection for analysis.

Returns a named tuple with metrics for both protection types.
"""
function compare_buffer_vs_floor(
    pricer::RILAPricer,
    buffer_rate::Float64,
    floor_rate::Float64,
    cap_rate::Float64,
    term_years::Int
)
    # Create mock products
    buffer_product = (
        company = "Compare",
        product_name = "Buffer",
        protection_type = :buffer,
        buffer_rate = buffer_rate,
        cap_rate = cap_rate,
        term_years = term_years
    )

    floor_product = (
        company = "Compare",
        product_name = "Floor",
        protection_type = :floor,
        buffer_rate = floor_rate,  # Floor level stored in buffer_rate field
        cap_rate = cap_rate,
        term_years = term_years
    )

    buffer_result = price(pricer, buffer_product)
    floor_result = price(pricer, floor_product)

    return (
        buffer = buffer_result,
        floor = floor_result
    )
end
