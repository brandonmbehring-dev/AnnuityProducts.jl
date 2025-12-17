# AnnuityProducts.jl

Product pricers for annuity products: GLWB, MYGA, FIA, and RILA.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/brandonmbehring-dev/AnnuityProducts.jl")
```

## Quick Start

```julia
using AnnuityProducts
using AnnuityData

# Load synthetic products
provider = SyntheticProvider()
products = load_products(provider, :myga)

# Price a MYGA product
pricer = MYGAPricer(flat_rate=0.04)
result = price(pricer, products[1])

# GLWB pricing
contract = GLWBContract(
    initial_premium = 100_000.0,
    rollup_rate = 0.05,
    rollup_years = 10,
    withdrawal_rate = 0.05,
    fee_rate = 0.015
)
config = GLWBPricingConfig(n_paths=10_000, seed=42)
glwb_result = price_glwb(contract, config)
```

## Features

### Product Pricers
- **MYGAPricer**: Multi-Year Guaranteed Annuity pricing
- **FIAPricer**: Fixed Indexed Annuity with option budget analysis
- **RILAPricer**: Buffer/floor RILA valuation

### GLWB Module
- **GLWBContract**: Contract specification with rollup, withdrawal rates
- **GLWBState**: State tracking (account value, GWB, withdrawal base)
- **simulate_glwb**: Monte Carlo path simulation
- **price_glwb**: Full GLWB pricing with analytics

### Behavioral Models
- **DynamicLapseModel**: Moneyness-based lapse rates
  - ITM guarantees lower lapse (rational behavior)
  - OTM guarantees higher lapse
  - Surrender period effects

### JuliaActuary Integration
- **MortalityTables.jl**: SOA mortality tables (`:IAM_2012_Male`, etc.)
- **FinanceModels.jl**: Yield curve construction

## Validation

- 218 tests passing
- 82 GLWB golden vector tests
- Cross-validated against Python annuity-pricing package

## Dependencies

- [AnnuityCore.jl](https://github.com/brandonmbehring-dev/AnnuityCore.jl): Core pricing engine
- [AnnuityData.jl](https://github.com/brandonmbehring-dev/AnnuityData.jl): Product schemas

## Testing

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

## License

MIT
