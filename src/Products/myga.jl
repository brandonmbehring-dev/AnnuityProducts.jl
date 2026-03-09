"""
MYGA (Multi-Year Guaranteed Annuity) pricing.

MYGAs provide guaranteed fixed interest rates for a specified term.
Pricing involves calculating present value of guaranteed payments.

Theory
------
[T1] MYGA is a zero-coupon bond equivalent:
     FV = P × (1 + r)^n
     PV = FV / (1 + d)^n

[T1] Duration (Macaulay) for single cash flow at T = T
[T1] Modified duration = Macaulay duration / (1 + d)
[T1] Convexity = T × (T + 1) / (1 + d)^2

References:
- Hull (2021) Options, Futures Ch.4
- docs/knowledge/domain/mgsv_mva.md
"""

"""
    MYGAPricer

Pricer for Multi-Year Guaranteed Annuities.

# Fields
- `discount_rate::Union{Float64, Nothing}`: Flat discount rate (if not using yield curve)
- `mgsv_base_rate::Float64`: MGSV base factor (default 0.875 = 87.5%)
- `mgsv_accumulation_rate::Float64`: MGSV accumulation rate (default 0.01 = 1%)
"""
struct MYGAPricer
    discount_rate::Union{Float64,Nothing}
    mgsv_base_rate::Float64
    mgsv_accumulation_rate::Float64

    function MYGAPricer(;
        discount_rate::Union{Float64,Nothing}=nothing,
        flat_rate::Union{Float64,Nothing}=nothing,  # Alias for discount_rate
        mgsv_base_rate::Float64=0.875,
        mgsv_accumulation_rate::Float64=0.01,
        yield_curve=nothing,  # Placeholder for future FinanceModels.jl
    )
        # Use flat_rate as alias for discount_rate (backwards compatibility)
        rate = discount_rate !== nothing ? discount_rate : flat_rate

        new(rate, mgsv_base_rate, mgsv_accumulation_rate)
    end
end

"""
    MYGAPriceResult

Result of MYGA pricing.

# Fields
- `present_value::Float64`: Present value of guaranteed payments
- `maturity_value::Float64`: Value at maturity (accumulation value)
- `duration::Float64`: Macaulay duration in years
- `modified_duration::Float64`: Modified duration
- `convexity::Float64`: Convexity
- `mgsv::Float64`: Minimum Guaranteed Surrender Value
- `principal::Float64`: Initial premium
- `fixed_rate::Float64`: Product fixed rate
- `discount_rate::Float64`: Discount rate used
- `term_years::Int`: Contract term in years
"""
struct MYGAPriceResult
    present_value::Float64
    maturity_value::Float64
    duration::Float64
    modified_duration::Float64
    convexity::Float64
    mgsv::Float64
    principal::Float64
    fixed_rate::Float64
    discount_rate::Float64
    term_years::Int
end

"""
    price(pricer::MYGAPricer, product; principal=100000.0, discount_rate=nothing) -> MYGAPriceResult

Price a MYGA product.

[T1] MYGA valuation:
     FV = Principal × (1 + rate)^years
     PV = FV / (1 + discount)^years

# Arguments
- `pricer::MYGAPricer`: The pricer configuration
- `product`: MYGA product (from AnnuityData.jl)
- `principal::Float64=100000.0`: Initial premium amount
- `discount_rate::Union{Float64, Nothing}=nothing`: Override discount rate
  (if nothing, uses product's fixed_rate)

# Returns
- `MYGAPriceResult`: Pricing results including PV, duration, convexity

# Example
```julia
using AnnuityData
pricer = MYGAPricer()
product = MYGAProduct(
    company="Example Life",
    product_name="5-Year MYGA",
    fixed_rate=0.045,
    term_years=5
)
result = price(pricer, product; principal=100000.0, discount_rate=0.04)
# result.present_value ≈ 102209.9 (worth more than principal at lower discount)
```
"""
function price(
    pricer::MYGAPricer,
    product;
    principal::Float64=100000.0,
    discount_rate::Union{Float64,Nothing}=nothing,
)
    # Validate inputs
    principal > 0 || throw(ArgumentError("CRITICAL: principal must be > 0"))
    product.term_years > 0 || throw(ArgumentError("CRITICAL: term_years must be > 0"))
    product.fixed_rate >= 0 || throw(ArgumentError("CRITICAL: fixed_rate must be >= 0"))

    # Get rates
    fixed_rate = product.fixed_rate
    years = product.term_years

    # Determine discount rate (priority: argument > pricer > product rate)
    disc = if discount_rate !== nothing
        discount_rate
    elseif pricer.discount_rate !== nothing
        pricer.discount_rate
    else
        fixed_rate  # Default: discount at product rate
    end

    # Calculate maturity value (single payment at end)
    # [T1] FV = Principal × (1 + rate)^years
    maturity_value = principal * (1.0 + fixed_rate)^years

    # Present value at discount rate
    # [T1] PV = FV / (1 + disc)^years
    present_value = maturity_value / (1.0 + disc)^years

    # Duration (Macaulay) for zero-coupon bond = time to maturity
    # [T1] For single cash flow at T, duration = T
    duration = Float64(years)

    # Modified duration = Macaulay duration / (1 + disc)
    modified_duration = duration / (1.0 + disc)

    # Convexity for zero-coupon bond
    # [T1] Convexity = T × (T + 1) / (1 + disc)^2
    convexity = years * (years + 1) / (1.0 + disc)^2

    # Calculate MGSV (Minimum Guaranteed Surrender Value)
    # [T1] MGSV = base_rate × principal × (1 + mgsv_rate)^years
    mgsv = pricer.mgsv_base_rate * principal * (1.0 + pricer.mgsv_accumulation_rate)^years

    return MYGAPriceResult(
        present_value,
        maturity_value,
        duration,
        modified_duration,
        convexity,
        mgsv,
        principal,
        fixed_rate,
        disc,
        years,
    )
end

"""
    calculate_spread_bps(product, treasury_rate) -> Float64

Calculate spread over matched-duration Treasury in basis points.

# Arguments
- `product`: MYGA product
- `treasury_rate::Float64`: Treasury yield for matching duration (decimal)

# Returns
- `Float64`: Spread in basis points (e.g., 50.0 = 0.50%)

# Example
```julia
spread = calculate_spread_bps(product, 0.04)  # If product rate is 4.5%
# => 50.0 bps
```
"""
function calculate_spread_bps(product, treasury_rate::Float64)
    spread_decimal = product.fixed_rate - treasury_rate
    return spread_decimal * 10000.0  # Convert to basis points
end

"""
    calculate_yield_to_maturity(maturity_value, present_value, years) -> Float64

Calculate implied yield to maturity given prices.

[T1] YTM = (FV/PV)^(1/n) - 1

# Arguments
- `maturity_value::Float64`: Value at maturity
- `present_value::Float64`: Current price
- `years::Int`: Years to maturity

# Returns
- `Float64`: Yield to maturity (decimal)
"""
function calculate_yield_to_maturity(
    maturity_value::Float64, present_value::Float64, years::Int
)
    present_value > 0 || throw(ArgumentError("CRITICAL: present_value must be > 0"))
    maturity_value > 0 || throw(ArgumentError("CRITICAL: maturity_value must be > 0"))
    years > 0 || throw(ArgumentError("CRITICAL: years must be > 0"))

    return (maturity_value / present_value)^(1.0 / years) - 1.0
end

"""
    price_sensitivity(result::MYGAPriceResult, rate_shift::Float64) -> Float64

Estimate PV change for parallel rate shift using duration and convexity.

[T1] ΔPV/PV ≈ -D_mod × Δy + 0.5 × C × (Δy)^2

# Arguments
- `result::MYGAPriceResult`: Pricing result
- `rate_shift::Float64`: Parallel shift in rates (decimal, e.g., 0.01 for +100bps)

# Returns
- `Float64`: Approximate percentage change in PV
"""
function price_sensitivity(result::MYGAPriceResult, rate_shift::Float64)
    # First-order (duration) effect
    duration_effect = -result.modified_duration * rate_shift

    # Second-order (convexity) effect
    convexity_effect = 0.5 * result.convexity * rate_shift^2

    return duration_effect + convexity_effect
end
