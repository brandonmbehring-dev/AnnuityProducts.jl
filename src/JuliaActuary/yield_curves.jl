"""
Yield curve integration via FinanceModels.jl.

Provides yield curve fitting and discount factor calculations.
"""

# NOTE: FinanceModels.jl integration is deferred until
# package installation is verified. For now, provide stub functions.

"""
    fit_yield_curve(rates::Vector{Tuple{Float64, Float64}}; method=:nelson_siegel) -> Any

Fit a yield curve to observed rates.

# Arguments
- `rates::Vector{Tuple{Float64, Float64}}`: Vector of (maturity, rate) tuples
- `method::Symbol=:nelson_siegel`: Fitting method
  - `:nelson_siegel`: Nelson-Siegel model
  - `:svensson`: Nelson-Siegel-Svensson (extended)
  - `:cubic_spline`: Cubic spline interpolation

# Returns
- Fitted yield curve object

# Example
```julia
# Fit to Treasury rates
rates = [
    (0.25, 0.0450),  # 3-month
    (0.5, 0.0460),   # 6-month
    (1.0, 0.0470),   # 1-year
    (2.0, 0.0450),   # 2-year
    (5.0, 0.0420),   # 5-year
    (10.0, 0.0440),  # 10-year
]
curve = fit_yield_curve(rates)
rate_5y = curve(5.0)  # Get rate at 5 years
```

# Notes
Requires FinanceModels.jl to be installed.
"""
function fit_yield_curve(
    rates::Vector{Tuple{Float64,Float64}}; method::Symbol=:nelson_siegel
)
    # TODO: Implement when FinanceModels.jl integration is ready
    # using FinanceModels
    # return FinanceModels.fit(NelsonSiegel(), rates)

    error(
        "FinanceModels.jl integration not yet implemented. " *
        "Install with: using Pkg; Pkg.add(\"FinanceModels\")",
    )
end

"""
    discount_factor(curve, t::Float64) -> Float64

Calculate discount factor at time t.

[T1] Discount factor: D(t) = exp(-r(t) × t)
where r(t) is the continuously compounded spot rate.

# Arguments
- `curve`: Fitted yield curve
- `t::Float64`: Time in years

# Returns
- `Float64`: Discount factor (between 0 and 1)

# Example
```julia
curve = fit_yield_curve(rates)
df_5y = discount_factor(curve, 5.0)  # ~0.80 for 4.5% rate
```
"""
function discount_factor(curve, t::Float64)
    t >= 0 || throw(ArgumentError("CRITICAL: t must be >= 0"))

    # TODO: Implement with real curve
    # rate = curve(t)
    # return exp(-rate * t)

    error("FinanceModels.jl integration not yet implemented")
end

"""
    forward_rate(curve, t1::Float64, t2::Float64) -> Float64

Calculate forward rate between times t1 and t2.

[T1] Forward rate: f(t1,t2) = [r(t2)×t2 - r(t1)×t1] / (t2 - t1)

# Arguments
- `curve`: Fitted yield curve
- `t1::Float64`: Start time in years
- `t2::Float64`: End time in years

# Returns
- `Float64`: Forward rate between t1 and t2
"""
function forward_rate(curve, t1::Float64, t2::Float64)
    t1 >= 0 || throw(ArgumentError("CRITICAL: t1 must be >= 0"))
    t2 > t1 || throw(ArgumentError("CRITICAL: t2 must be > t1"))

    # TODO: Implement with real curve
    error("FinanceModels.jl integration not yet implemented")
end

"""
    present_value(curve, cashflows::Vector{Tuple{Float64, Float64}}) -> Float64

Calculate present value of a series of cashflows.

# Arguments
- `curve`: Fitted yield curve
- `cashflows::Vector{Tuple{Float64, Float64}}`: Vector of (time, amount) tuples

# Returns
- `Float64`: Present value of all cashflows

# Example
```julia
# PV of 5 annual payments of 1000
cashflows = [(1.0, 1000.0), (2.0, 1000.0), (3.0, 1000.0), (4.0, 1000.0), (5.0, 1000.0)]
pv = present_value(curve, cashflows)
```
"""
function present_value(curve, cashflows::Vector{Tuple{Float64,Float64}})
    # TODO: Implement with real curve
    # return sum(amount * discount_factor(curve, t) for (t, amount) in cashflows)

    error("FinanceModels.jl integration not yet implemented")
end

# ============================================================================
# Simple flat rate implementations for testing
# ============================================================================

"""
    FlatRateCurve

Simple flat yield curve for testing and development.
"""
struct FlatRateCurve
    rate::Float64
end

"""Get rate at any maturity (constant for flat curve)."""
(curve::FlatRateCurve)(t::Float64) = curve.rate

"""Discount factor for flat rate curve."""
function discount_factor(curve::FlatRateCurve, t::Float64)
    t >= 0 || throw(ArgumentError("CRITICAL: t must be >= 0"))
    return exp(-curve.rate * t)
end

"""Forward rate for flat curve (equals spot rate)."""
function forward_rate(curve::FlatRateCurve, t1::Float64, t2::Float64)
    return curve.rate
end

"""Present value using flat curve."""
function present_value(curve::FlatRateCurve, cashflows::Vector{Tuple{Float64,Float64}})
    return sum(amount * discount_factor(curve, t) for (t, amount) in cashflows)
end
