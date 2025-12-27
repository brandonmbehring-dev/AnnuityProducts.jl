# AnnuityProducts.jl

Product pricers for annuity products: GLWB, MYGA, FIA, RILA. Application layer of the Annuity Julia package suite.

## Development

### Build & Test

```bash
# Run all tests (218 tests)
julia --project=. -e "using Pkg; Pkg.test()"

# Run specific test file
julia --project=. test/glwb_test.jl

# REPL development
julia --project=.
```

### Architecture Notes

**Package Suite Hierarchy**:
```
AnnuityCore.jl  (base math layer)
    ↑
AnnuityData.jl  (product schemas)
    ↑
AnnuityProducts.jl  ← YOU ARE HERE (application layer)
```

**This package integrates both dependencies**:
- Uses `AnnuityCore` for Black-Scholes, Greeks, payoff calculations
- Uses `AnnuityData` for product schemas and fixtures

**Key Components**:

1. **Product Pricers** (`MYGAPricer`, `FIAPricer`, `RILAPricer`)
   - Dispatch on product schema from AnnuityData
   - Use math from AnnuityCore

2. **GLWB Module** (most complex)
   - Monte Carlo path simulation
   - Behavioral lapse models (moneyness-based)
   - 82 golden vector tests for reproducibility

3. **MortalityTables.jl Integration**
   - SOA mortality tables (`:IAM_2012_Male`, etc.)
   - Required for GLWB lifetime projections

### Testing Patterns

**Golden vectors for GLWB**:
- 82 pre-computed test cases in `test/fixtures/`
- Seed-locked (`StableRNGs`) for reproducibility
- Cross-validated against Python `annuity-pricing`

**Adding new tests**:
1. Use deterministic seed via `StableRNG`
2. Store expected outputs as fixtures (not inline)
3. Test both happy path AND edge cases (zero premium, 100% lapse, etc.)

### Cross-Validation

Python reference implementation: `annuity-pricing` package
- Same synthetic data (SyntheticProvider seeds match)
- Same algorithms (BS formula, GLWB simulation)
- Tolerance: 1e-6 for pricing, 1e-4 for Monte Carlo

## Contributing

**Adding a new pricer**:
1. Define pricer struct with configuration
2. Implement `price(pricer, product)` method
3. Add golden vector tests with fixed seed
4. Cross-validate against Python if applicable

**GLWB changes require extra care**:
- Golden vectors must be regenerated if algorithm changes
- Document any changes in test/CHANGELOG.md

---

**Hub**: @~/Claude/lever_of_archimedes/
**Related**: AnnuityCore.jl, AnnuityData.jl
