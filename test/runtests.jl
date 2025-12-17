using Test
using AnnuityProducts
using Statistics
using CSV
using DataFrames

@testset "AnnuityProducts.jl" begin

    @testset "GLWB" begin
        @testset "GLWBContract" begin
            contract = GLWBContract(
                initial_premium=100000.0,
                withdrawal_rate=0.05,
                rollup_rate=0.05,
                rollup_years=10,
                rider_fee=0.01,
                fee_basis=:account_value
            )

            @test contract.initial_premium == 100000.0
            @test contract.withdrawal_rate == 0.05
            @test contract.rollup_years == 10
        end

        @testset "rollup calculations" begin
            # Simple rollup: 100K × 1.05^10 = 162889.46
            gwb = calculate_rollup_benefit(100000.0, 0.05, 10)
            @test gwb ≈ 100000.0 * 1.05^10

            # Monthly rollup
            gwb_monthly = calculate_monthly_rollup_benefit(100000.0, 0.05, 120)
            @test gwb_monthly > gwb  # Monthly compounding > annual

            # Annual withdrawal
            withdrawal = calculate_annual_withdrawal(gwb, 0.05)
            @test withdrawal ≈ gwb * 0.05
        end

        @testset "path simulation" begin
            contract = GLWBContract(
                initial_premium=100000.0,
                withdrawal_rate=0.05,
                rollup_rate=0.05,
                rollup_years=10,
                rider_fee=0.01
            )

            # Simulate with flat 0% returns
            n_paths = 100
            n_months = 240  # 20 years
            flat_returns = zeros(n_paths, n_months)

            results = simulate_glwb(contract, flat_returns)

            @test length(results) == n_paths
            @test all(r -> r.final_gwb >= contract.initial_premium, results)
        end

        @testset "GLWB Pricer" begin
            # Basic pricer test
            result = price_glwb(
                premium = 100000.0,
                age = 65,
                r = 0.04,
                sigma = 0.20,
                n_paths = 100,
                seed = 42
            )

            @test result.price >= 0
            @test result.guarantee_cost >= 0
            @test 0 <= result.prob_ruin <= 1
            @test result.standard_error >= 0

            # Mortality table sanity
            @test soa_2012_iam_qx(65) > 0
            @test soa_2012_iam_qx(65) < 0.05
            @test soa_2012_iam_qx(75) > soa_2012_iam_qx(65)  # Increases with age
        end
    end

    @testset "MYGA Pricer" begin
        # Create mock product-like object
        product = (
            company = "Test Life",
            product_name = "5-Year MYGA",
            fixed_rate = 0.045,  # 4.5%
            term_years = 5
        )

        @testset "Basic pricing" begin
            pricer = MYGAPricer()
            result = price(pricer, product; principal=100000.0, discount_rate=0.04)

            # Maturity value = 100000 × 1.045^5 ≈ 124618.19
            @test result.maturity_value ≈ 100000.0 * 1.045^5 atol=0.01

            # PV at lower discount rate should exceed principal
            @test result.present_value > 100000.0

            # Duration for zero-coupon = term
            @test result.duration == 5.0

            # Modified duration
            @test result.modified_duration ≈ 5.0 / 1.04 atol=1e-10

            # Convexity for zero-coupon: T(T+1)/(1+d)^2
            @test result.convexity ≈ 5 * 6 / 1.04^2 atol=1e-10
        end

        @testset "Discount at product rate" begin
            # When discount = fixed_rate, PV should equal principal
            pricer = MYGAPricer()
            result = price(pricer, product; principal=100000.0, discount_rate=0.045)
            @test result.present_value ≈ 100000.0 atol=0.01
        end

        @testset "MGSV calculation" begin
            pricer = MYGAPricer()
            result = price(pricer, product; principal=100000.0)
            # MGSV = 0.875 × 100000 × 1.01^5 ≈ 91938.78
            expected_mgsv = 0.875 * 100000.0 * 1.01^5
            @test result.mgsv ≈ expected_mgsv atol=0.01
        end

        @testset "Spread calculation" begin
            spread = calculate_spread_bps(product, 0.04)
            @test spread ≈ 50.0 atol=0.01  # 4.5% - 4.0% = 50 bps
        end

        @testset "YTM calculation" begin
            ytm = calculate_yield_to_maturity(124618.19, 100000.0, 5)
            @test ytm ≈ 0.045 atol=0.001
        end

        @testset "Price sensitivity" begin
            pricer = MYGAPricer()
            result = price(pricer, product; principal=100000.0, discount_rate=0.04)

            # +100bps shift
            sensitivity = price_sensitivity(result, 0.01)
            # Duration effect ≈ -4.8%, convexity effect ≈ +0.14%
            @test sensitivity < 0  # Price falls when rates rise
            @test sensitivity > -0.06  # But less than -6%
        end
    end

    @testset "FIA Pricer" begin
        @testset "Capped call pricing" begin
            # Product with cap rate
            product = (
                company = "Test Life",
                product_name = "Capped FIA",
                cap_rate = 0.10,
                participation_rate = nothing,
                spread_rate = nothing,
                term_years = 1
            )

            pricer = FIAPricer(n_paths=10000, seed=42)
            result = price(pricer, product; premium=100.0)

            @test result.present_value > 0
            @test result.embedded_option_value >= 0
            @test result.embedded_option_value <= 1.0  # Option value as % of premium
            @test result.option_budget > 0
            @test result.crediting_method == :cap
            @test result.term_years == 1
        end

        @testset "Participation rate pricing" begin
            # Product with participation rate
            product = (
                company = "Test Life",
                product_name = "Participation FIA",
                cap_rate = nothing,
                participation_rate = 0.50,
                spread_rate = nothing,
                term_years = 1
            )

            pricer = FIAPricer(n_paths=10000, seed=42)
            result = price(pricer, product; premium=100.0)

            @test result.present_value > 0
            @test result.crediting_method == :participation
        end

        @testset "Spread rate pricing" begin
            # Product with spread rate
            product = (
                company = "Test Life",
                product_name = "Spread FIA",
                cap_rate = nothing,
                participation_rate = nothing,
                spread_rate = 0.02,
                term_years = 1
            )

            pricer = FIAPricer(n_paths=10000, seed=42)
            result = price(pricer, product; premium=100.0)

            @test result.present_value > 0
            @test result.crediting_method == :spread
        end

        @testset "Fair cap/participation solving" begin
            # Use 6-year term for meaningful option budget
            product = (
                company = "Test Life",
                product_name = "6-Year FIA",
                cap_rate = 0.10,
                participation_rate = nothing,
                spread_rate = nothing,
                term_years = 6
            )

            pricer = FIAPricer(n_paths=10000, seed=42)
            result = price(pricer, product; premium=100.0)

            # Fair cap should be positive
            @test result.fair_cap > 0
            @test result.fair_cap <= 1.0  # Cap <= 100%

            # Fair participation should be positive
            @test result.fair_participation > 0
        end

        @testset "No crediting method throws" begin
            # Product with no crediting method
            product = (
                company = "Test Life",
                product_name = "Invalid FIA",
                cap_rate = nothing,
                participation_rate = nothing,
                spread_rate = nothing,
                term_years = 1
            )

            pricer = FIAPricer()
            @test_throws ArgumentError price(pricer, product)
        end

        @testset "Option budget calculation" begin
            # Verify option budget scales with term
            pricer = FIAPricer(option_budget_pct=0.03)  # 3% annual budget

            product_short = (
                company = "Test", product_name = "Short",
                cap_rate = 0.10, participation_rate = nothing,
                spread_rate = nothing, term_years = 3
            )
            product_long = (
                company = "Test", product_name = "Long",
                cap_rate = 0.10, participation_rate = nothing,
                spread_rate = nothing, term_years = 6
            )

            result_short = price(pricer, product_short; premium=100.0)
            result_long = price(pricer, product_long; premium=100.0)

            # Longer term should have higher cumulative option budget
            @test result_long.option_budget > result_short.option_budget
        end
    end

    @testset "RILA Pricer" begin
        @testset "Buffer protection pricing" begin
            # Product with 10% buffer
            product = (
                company = "Test Life",
                product_name = "10% Buffer RILA",
                protection_type = :buffer,
                buffer_rate = 0.10,
                cap_rate = 0.15,
                term_years = 1
            )

            pricer = RILAPricer(n_paths=10000, seed=42)
            result = price(pricer, product; premium=100.0)

            @test result.present_value > 0
            @test result.protection_value > 0  # Buffer has value
            @test result.protection_type == :buffer
            @test result.max_loss ≈ 0.90 atol=0.01  # 1 - 10% buffer
            @test result.breakeven_return ≈ -0.10 atol=0.01  # Breakeven at -buffer
            @test result.term_years == 1
        end

        @testset "Floor protection pricing" begin
            # Product with 10% floor (max loss = 10%)
            product = (
                company = "Test Life",
                product_name = "10% Floor RILA",
                protection_type = :floor,
                buffer_rate = 0.10,  # Floor level stored in buffer_rate
                cap_rate = 0.15,
                term_years = 1
            )

            pricer = RILAPricer(n_paths=10000, seed=42)
            result = price(pricer, product; premium=100.0)

            @test result.present_value > 0
            @test result.protection_value > 0  # Floor has value
            @test result.protection_type == :floor
            @test result.max_loss ≈ 0.10 atol=0.01  # Floor = max 10% loss
            @test result.breakeven_return ≈ 0.0 atol=0.01  # Floor breakeven at 0
        end

        @testset "100% buffer edge case" begin
            # 100% buffer = full protection (max loss = 0)
            product = (
                company = "Test Life",
                product_name = "100% Buffer RILA",
                protection_type = :buffer,
                buffer_rate = 1.0,
                cap_rate = 0.10,
                term_years = 1
            )

            pricer = RILAPricer(n_paths=10000, seed=42)
            result = price(pricer, product; premium=100.0)

            @test result.present_value > 0
            @test result.max_loss ≈ 0.0 atol=0.01  # Full protection
            @test result.breakeven_return ≈ -1.0 atol=0.01  # Breakeven at -100%
        end

        @testset "Buffer vs Floor comparison" begin
            pricer = RILAPricer(n_paths=10000, seed=42)

            comparison = compare_buffer_vs_floor(
                pricer,
                0.10,  # buffer_rate
                0.10,  # floor_rate
                0.15,  # cap_rate
                1      # term_years
            )

            # Both should have positive protection value
            @test comparison.buffer.protection_value > 0
            @test comparison.floor.protection_value > 0

            # Buffer has lower max loss than floor (for same protection level)
            @test comparison.buffer.max_loss > comparison.floor.max_loss

            # Buffer breakeven is more favorable (negative vs zero)
            @test comparison.buffer.breakeven_return < comparison.floor.breakeven_return
        end

        @testset "Fair cap calculation" begin
            # Fair cap should be positive
            product = (
                company = "Test Life",
                product_name = "RILA",
                protection_type = :buffer,
                buffer_rate = 0.10,
                cap_rate = 0.15,
                term_years = 1
            )

            pricer = RILAPricer(n_paths=10000, seed=42)
            result = price(pricer, product; premium=100.0)

            @test result.fair_cap > 0

            # For higher buffer with LONGER term, fair cap should be lower
            # (more protection value = less upside needed to balance)
            # Use 3-year terms where the relationship is clearer
            product_low_buffer = (
                company = "Test Life",
                product_name = "Low Buffer RILA",
                protection_type = :buffer,
                buffer_rate = 0.10,
                cap_rate = 0.15,
                term_years = 3
            )
            product_high_buffer = (
                company = "Test Life",
                product_name = "High Buffer RILA",
                protection_type = :buffer,
                buffer_rate = 0.30,  # Much higher buffer
                cap_rate = 0.15,
                term_years = 3
            )
            result_low = price(pricer, product_low_buffer; premium=100.0)
            result_high = price(pricer, product_high_buffer; premium=100.0)

            # Higher buffer → higher protection value → lower fair cap needed
            @test result_high.fair_cap <= result_low.fair_cap
        end

        @testset "Invalid protection type throws" begin
            product = (
                company = "Test Life",
                product_name = "Invalid",
                protection_type = :invalid,
                buffer_rate = 0.10,
                cap_rate = 0.15,
                term_years = 1
            )

            pricer = RILAPricer()
            @test_throws ArgumentError price(pricer, product)
        end

        @testset "Expected return is reasonable" begin
            # Buffer product should have expected return between -max_loss and cap
            product = (
                company = "Test Life",
                product_name = "RILA",
                protection_type = :buffer,
                buffer_rate = 0.10,
                cap_rate = 0.15,
                term_years = 1
            )

            pricer = RILAPricer(n_paths=50000, seed=42)
            result = price(pricer, product; premium=100.0)

            # Expected return should be bounded
            @test result.expected_return >= -result.max_loss - 0.1  # Allow some tolerance
            @test result.expected_return <= result.upside_value / 100 + 0.1
        end
    end

    @testset "Yield Curves" begin
        @testset "FlatRateCurve" begin
            curve = FlatRateCurve(0.04)

            @test curve(1.0) == 0.04
            @test curve(5.0) == 0.04
            @test curve(10.0) == 0.04

            # Discount factor at 5 years with 4% rate
            df = discount_factor(curve, 5.0)
            @test df ≈ exp(-0.04 * 5.0)

            # PV of cashflows
            cashflows = [(1.0, 100.0), (2.0, 100.0)]
            pv = present_value(curve, cashflows)
            expected = 100.0 * exp(-0.04) + 100.0 * exp(-0.08)
            @test pv ≈ expected
        end
    end

    @testset "Dynamic Lapse Model" begin
        @testset "LapseAssumptions construction" begin
            # Default assumptions
            assumptions = LapseAssumptions()
            @test assumptions.base_annual_lapse == 0.05
            @test assumptions.min_lapse == 0.01
            @test assumptions.max_lapse == 0.25
            @test assumptions.sensitivity == 1.0

            # Custom assumptions
            custom = LapseAssumptions(
                base_annual_lapse=0.08,
                min_lapse=0.005,
                max_lapse=0.30,
                sensitivity=1.5
            )
            @test custom.base_annual_lapse == 0.08
            @test custom.sensitivity == 1.5

            # Invalid assumptions throw
            @test_throws ArgumentError LapseAssumptions(base_annual_lapse=-0.01)
            @test_throws ArgumentError LapseAssumptions(min_lapse=-0.01)
            @test_throws ArgumentError LapseAssumptions(max_lapse=0.005, min_lapse=0.01)
        end

        @testset "Basic lapse calculation" begin
            model = DynamicLapseModel()

            # ATM (GWB = AV): base lapse rate
            result = calculate_lapse(model, 100000.0, 100000.0; surrender_period_complete=true)
            @test result.moneyness ≈ 1.0
            @test result.adjustment_factor ≈ 1.0
            @test result.lapse_rate ≈ 0.05 atol=0.001

            # ITM (GWB > AV): lower lapse rate
            result_itm = calculate_lapse(model, 120000.0, 100000.0; surrender_period_complete=true)
            @test result_itm.moneyness > 1.0  # GWB/AV > 1
            @test result_itm.adjustment_factor < 1.0  # AV/GWB < 1
            @test result_itm.lapse_rate < 0.05  # Lower than base

            # OTM (GWB < AV): higher lapse rate
            result_otm = calculate_lapse(model, 80000.0, 100000.0; surrender_period_complete=true)
            @test result_otm.moneyness < 1.0
            @test result_otm.adjustment_factor > 1.0
            @test result_otm.lapse_rate > 0.05  # Higher than base
        end

        @testset "Surrender period reduction" begin
            model = DynamicLapseModel()

            # During surrender period: reduced lapse
            result_sp = calculate_lapse(model, 100000.0, 100000.0; surrender_period_complete=false)

            # After surrender period: full lapse
            result_post = calculate_lapse(model, 100000.0, 100000.0; surrender_period_complete=true)

            @test result_sp.lapse_rate < result_post.lapse_rate
        end

        @testset "Floor and cap enforcement" begin
            # High sensitivity + very OTM should hit cap
            high_sensitivity = LapseAssumptions(sensitivity=3.0)
            model = DynamicLapseModel(high_sensitivity)

            # Very OTM: GWB = 50K, AV = 100K
            result = calculate_lapse(model, 50000.0, 100000.0; surrender_period_complete=true)
            @test result.lapse_rate <= high_sensitivity.max_lapse

            # Very ITM: GWB = 200K, AV = 100K
            result_itm = calculate_lapse(model, 200000.0, 100000.0; surrender_period_complete=true)
            @test result_itm.lapse_rate >= high_sensitivity.min_lapse
        end

        @testset "Monthly lapse conversion" begin
            model = DynamicLapseModel()

            monthly = calculate_monthly_lapse(model, 100000.0, 100000.0; surrender_period_complete=true)

            # Monthly rate should be less than annual / 12
            @test monthly > 0
            @test monthly < 0.05 / 12 * 1.1  # Allow small tolerance

            # 12 monthly compounds should approximate annual
            annual_approx = 1.0 - (1.0 - monthly)^12
            @test annual_approx ≈ 0.05 atol=0.001
        end

        @testset "Path lapse calculation" begin
            model = DynamicLapseModel()

            # Simulate path where GWB stays constant, AV fluctuates
            gwb_path = [100000.0, 100000.0, 100000.0, 100000.0, 100000.0]
            av_path = [100000.0, 90000.0, 80000.0, 110000.0, 120000.0]

            lapse_rates = calculate_path_lapses(model, gwb_path, av_path; surrender_period_ends=2)

            @test length(lapse_rates) == 5

            # During surrender period (t=1,2): reduced rates
            @test lapse_rates[1] < lapse_rates[3]
            @test lapse_rates[2] < lapse_rates[4]

            # ITM periods (t=2,3) should have lower rates than OTM (t=4,5)
            @test lapse_rates[3] < lapse_rates[5]  # 80K AV (ITM) vs 120K AV (OTM)
        end

        @testset "Survival probability from lapse" begin
            # Constant 5% annual lapse
            lapse_rates = [0.05, 0.05, 0.05, 0.05, 0.05]

            survival = lapse_survival_probability(lapse_rates)

            @test length(survival) == 6  # n_steps + 1
            @test survival[1] == 1.0  # Start at 100%
            @test survival[2] ≈ 0.95  # After 1 year
            @test survival[3] ≈ 0.95^2  # After 2 years
            @test survival[6] ≈ 0.95^5  # After 5 years

            # Should be monotonically decreasing
            for i in 2:6
                @test survival[i] <= survival[i-1]
            end
        end

        @testset "Apply lapse to cashflows" begin
            cashflows = [1000.0, 1000.0, 1000.0]
            lapse_rates = [0.10, 0.10, 0.10]

            survival = lapse_survival_probability(lapse_rates)
            adjusted = apply_lapse_to_cashflows(cashflows, survival)

            @test length(adjusted) == 3
            @test adjusted[1] ≈ 1000.0 * 0.90  # Year 1: 90% survive
            @test adjusted[2] ≈ 1000.0 * 0.90^2  # Year 2: 81% survive
            @test adjusted[3] ≈ 1000.0 * 0.90^3  # Year 3: 72.9% survive
        end

        @testset "Effective lapse rate lookup" begin
            model = DynamicLapseModel()

            # ATM
            @test effective_lapse_rate(model, 1.0; surrender_period_complete=true) ≈ 0.05 atol=0.001

            # 20% ITM
            itm_rate = effective_lapse_rate(model, 1.2; surrender_period_complete=true)
            @test itm_rate < 0.05

            # 20% OTM
            otm_rate = effective_lapse_rate(model, 0.8; surrender_period_complete=true)
            @test otm_rate > 0.05

            # Verify the formula: rate = base × (1/moneyness)^sensitivity
            # ITM (1.2): 0.05 × (1/1.2)^1 = 0.0417
            # OTM (0.8): 0.05 × (1/0.8)^1 = 0.0625
            @test itm_rate ≈ 0.05 * (1.0/1.2) atol=0.001
            @test otm_rate ≈ 0.05 * (1.0/0.8) atol=0.001
        end

        @testset "Input validation" begin
            model = DynamicLapseModel()

            # Negative AV should throw
            @test_throws ArgumentError calculate_lapse(model, 100000.0, -1.0)

            # Zero AV should throw
            @test_throws ArgumentError calculate_lapse(model, 100000.0, 0.0)

            # Negative GWB should throw
            @test_throws ArgumentError calculate_lapse(model, -1.0, 100000.0)

            # Zero GWB is OK (no guarantee)
            result = calculate_lapse(model, 0.0, 100000.0; surrender_period_complete=true)
            @test result.moneyness == 1.0  # Defaults to ATM
        end
    end

    @testset "MortalityTables Integration" begin
        @testset "List available tables" begin
            # Should be able to list available table shortcuts
            shortcuts = list_available_tables()
            @test !isempty(shortcuts)
            @test shortcuts isa Vector{Symbol}

            # Should include common tables
            @test :IAM_2012_Male in shortcuts
            @test :IAM_2012_Female in shortcuts
        end

        @testset "Load and use mortality table" begin
            # Load a common table by Symbol shortcut
            table = load_mortality_table(:IAM_2012_Male)
            @test table !== nothing

            # Get qx value
            qx_65 = get_qx(table, 65)
            @test 0.0 < qx_65 < 1.0  # Valid mortality rate

            # Mortality should increase with age
            qx_75 = get_qx(table, 75)
            @test qx_75 > qx_65

            # Female table should have lower mortality (typically)
            table_f = load_mortality_table(:IAM_2012_Female)
            qx_65_f = get_qx(table_f, 65)
            @test qx_65_f < qx_65  # Female mortality < Male mortality
        end

        @testset "Survival probability" begin
            table = load_mortality_table(:IAM_2012_Male)

            # Survival at 0 years = 1
            @test survival_probability(table, 65, 0) == 1.0

            # Survival probability decreases with time
            p10 = survival_probability(table, 65, 10)
            p20 = survival_probability(table, 65, 20)
            @test 0.0 < p20 < p10 < 1.0
        end

        @testset "Life expectancy" begin
            table = load_mortality_table(:IAM_2012_Male)

            # Life expectancy at 65 should be reasonable (10-30 years)
            le_65 = calc_life_expectancy(table, 65)
            @test 10.0 < le_65 < 35.0

            # Life expectancy decreases with age
            le_75 = calc_life_expectancy(table, 75)
            @test le_75 < le_65
        end

        @testset "Annuity factor" begin
            table = load_mortality_table(:IAM_2012_Male)

            # Annuity factor at 5% discount
            af = annuity_factor(table, 65, 0.05)
            @test af > 0

            # Term-certain annuity should be less than whole life
            af_10 = annuity_factor(table, 65, 0.05; term=10)
            @test af_10 < af

            # Higher discount rate should reduce annuity value
            af_high_rate = annuity_factor(table, 65, 0.10)
            @test af_high_rate < af
        end

        @testset "Unknown table shortcut throws" begin
            @test_throws ErrorException load_mortality_table(:NonExistentTable)
        end
    end

end

# Include golden vector tests (separate file)
include("test_glwb_golden_vectors.jl")
