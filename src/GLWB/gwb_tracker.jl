"""
GWB (Guaranteed Withdrawal Base) account tracking.

Tracks the state of a GLWB contract over time including:
- Account value (subject to market performance)
- Guaranteed withdrawal base (GWB)
- Cumulative withdrawals

References:
- Bauer, Kling & Russ (2008) "A Universal Pricing Framework for Guaranteed Minimum Benefits"
"""

"""
    GLWBContract

Parameters for a GLWB contract.

# Fields
- `initial_premium::Float64`: Initial premium payment
- `withdrawal_rate::Float64`: Annual withdrawal rate as percent of GWB (e.g., 0.05 for 5%)
- `rollup_rate::Float64`: Annual rollup rate during deferral (e.g., 0.05 for 5%)
- `rollup_years::Int`: Number of years the rollup applies
- `rider_fee::Float64`: Annual rider fee rate (e.g., 0.01 for 1%)
- `fee_basis::Symbol`: Fee calculation basis - `:account_value` or `:gwb`
"""
struct GLWBContract
    initial_premium::Float64
    withdrawal_rate::Float64
    rollup_rate::Float64
    rollup_years::Int
    rider_fee::Float64
    fee_basis::Symbol

    function GLWBContract(;
        initial_premium::Float64,
        withdrawal_rate::Float64,
        rollup_rate::Float64,
        rollup_years::Int,
        rider_fee::Float64,
        fee_basis::Symbol=:account_value,
    )
        initial_premium > 0 || throw(ArgumentError("CRITICAL: initial_premium must be > 0"))
        withdrawal_rate >= 0 ||
            throw(ArgumentError("CRITICAL: withdrawal_rate must be >= 0"))
        rollup_rate >= 0 || throw(ArgumentError("CRITICAL: rollup_rate must be >= 0"))
        rollup_years >= 0 || throw(ArgumentError("CRITICAL: rollup_years must be >= 0"))
        rider_fee >= 0 || throw(ArgumentError("CRITICAL: rider_fee must be >= 0"))
        fee_basis in (:account_value, :gwb) ||
            throw(ArgumentError("CRITICAL: fee_basis must be :account_value or :gwb"))

        new(
            initial_premium,
            withdrawal_rate,
            rollup_rate,
            rollup_years,
            rider_fee,
            fee_basis,
        )
    end
end

"""
    GLWBState

Current state of a GLWB contract.

# Fields
- `account_value::Float64`: Current account value
- `gwb::Float64`: Guaranteed withdrawal base
- `cumulative_withdrawals::Float64`: Total withdrawals to date
- `month::Int`: Current month (0 = inception)
- `in_payout_phase::Bool`: Whether withdrawals have begun
"""
mutable struct GLWBState
    account_value::Float64
    gwb::Float64
    cumulative_withdrawals::Float64
    month::Int
    in_payout_phase::Bool
end

"""Create initial state from contract."""
function initial_state(contract::GLWBContract)
    return GLWBState(
        contract.initial_premium,  # account_value
        contract.initial_premium,  # gwb = initial premium
        0.0,                       # cumulative_withdrawals
        0,                         # month
        false,                      # not in payout phase yet
    )
end

"""
    GLWBResult

Result of GLWB simulation for a single path.

# Fields
- `final_account_value::Float64`: Account value at simulation end
- `final_gwb::Float64`: GWB at simulation end
- `total_withdrawals::Float64`: Sum of all withdrawals
- `total_fees::Float64`: Sum of all rider fees paid
- `months_in_payout::Int`: Number of months with withdrawals
- `account_depleted::Bool`: Whether account value reached zero
"""
struct GLWBResult
    final_account_value::Float64
    final_gwb::Float64
    total_withdrawals::Float64
    total_fees::Float64
    months_in_payout::Int
    account_depleted::Bool
end

"""
    step_month!(state, contract, monthly_return, take_withdrawal) -> (withdrawal, fee)

Advance the GLWB state by one month.

# Arguments
- `state::GLWBState`: Current state (modified in place)
- `contract::GLWBContract`: Contract parameters
- `monthly_return::Float64`: Monthly investment return (e.g., 0.01 for 1%)
- `take_withdrawal::Bool`: Whether to take a withdrawal this month

# Returns
- `Tuple{Float64, Float64}`: (withdrawal amount, fee amount)

# Notes
Order of operations per month:
1. Apply investment return to account value
2. Deduct rider fee
3. Apply rollup to GWB (if in deferral phase and eligible)
4. Process withdrawal (if requested)
5. Update GWB high-water mark
"""
function step_month!(
    state::GLWBState, contract::GLWBContract, monthly_return::Float64, take_withdrawal::Bool
)
    state.month += 1

    # 1. Apply investment return
    state.account_value *= (1.0 + monthly_return)

    # 2. Deduct rider fee (monthly)
    monthly_fee_rate = contract.rider_fee / 12.0
    fee_basis_value = contract.fee_basis == :account_value ? state.account_value : state.gwb
    fee = fee_basis_value * monthly_fee_rate
    state.account_value = max(0.0, state.account_value - fee)

    # 3. Apply rollup (monthly, during deferral phase only)
    if !state.in_payout_phase && state.month <= contract.rollup_years * 12
        monthly_rollup_rate = contract.rollup_rate / 12.0
        state.gwb *= (1.0 + monthly_rollup_rate)
    end

    # 4. Process withdrawal
    withdrawal = 0.0
    if take_withdrawal
        state.in_payout_phase = true

        # Monthly withdrawal = annual rate × GWB / 12
        monthly_withdrawal = contract.withdrawal_rate * state.gwb / 12.0

        # Withdrawal comes from account value, but guaranteed by GWB
        actual_from_account = min(monthly_withdrawal, state.account_value)
        state.account_value -= actual_from_account

        # The guaranteed portion (if account is depleted)
        withdrawal = monthly_withdrawal  # Guaranteed amount
        state.cumulative_withdrawals += withdrawal
    end

    # 5. Update GWB high-water mark (step-up)
    if state.account_value > state.gwb
        state.gwb = state.account_value
    end

    return (withdrawal, fee)
end
