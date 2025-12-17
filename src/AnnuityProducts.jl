"""
    AnnuityProducts

Product pricers for annuity products: GLWB, MYGA, FIA, RILA.

This package provides:
- GLWB (Guaranteed Lifetime Withdrawal Benefit) pricing
- MYGA (Multi-Year Guaranteed Annuity) pricing
- FIA (Fixed Indexed Annuity) pricing
- RILA (Registered Index-Linked Annuity) pricing
- JuliaActuary integration (MortalityTables.jl, FinanceModels.jl)

Depends on:
- AnnuityCore.jl: Core pricing engine (BS, MC, payoffs)
- AnnuityData.jl: Product schemas and data providers

# Example
```julia
using AnnuityProducts
using AnnuityData

# Load synthetic products
provider = SyntheticProvider()
products = load_products(provider, :myga)

# Price a MYGA product
pricer = MYGAPricer(flat_rate=0.04)
result = price(pricer, products[1])
```
"""
module AnnuityProducts

using AnnuityCore
using AnnuityData
using Distributions
using Random: AbstractRNG
using StableRNGs
using Statistics: mean, std, var

# GLWB module
include("GLWB/gwb_tracker.jl")
include("GLWB/rollup.jl")
include("GLWB/path_sim.jl")
include("GLWB/pricer.jl")

# Product pricers
include("Products/myga.jl")
include("Products/fia.jl")
include("Products/rila.jl")

# Behavioral models
include("Behavioral/lapse.jl")

# JuliaActuary integration
include("JuliaActuary/mortality.jl")
include("JuliaActuary/yield_curves.jl")

# GLWB exports
export GLWBContract, GLWBState, GLWBResult
export step_month!, simulate_glwb, initial_state
export calculate_rollup_benefit, calculate_monthly_rollup_benefit, calculate_annual_withdrawal
# GLWB pricer exports
export GLWBPricingConfig, GLWBPricingResult, price_glwb
export soa_2012_iam_qx

# Product pricer exports
export MYGAPricer, MYGAPriceResult
export FIAPricer, FIAPriceResult
export RILAPricer, RILAPriceResult
export price
export calculate_spread_bps, calculate_yield_to_maturity, price_sensitivity
export compare_buffer_vs_floor

# Behavioral exports (lapse model)
export LapseAssumptions, LapseResult, DynamicLapseModel
export calculate_lapse, calculate_monthly_lapse
export calculate_path_lapses, lapse_survival_probability
export apply_lapse_to_cashflows, effective_lapse_rate

# JuliaActuary exports
export load_mortality_table, get_qx, survival_probability
export calc_life_expectancy, annuity_factor, list_available_tables
export fit_yield_curve, discount_factor, forward_rate, present_value
export FlatRateCurve

end # module AnnuityProducts
