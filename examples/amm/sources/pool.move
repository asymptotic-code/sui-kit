#[allow(unused_function)]
module amm::pool;

use std::u128;
use std::u64;
use sui::balance::{Self, Balance, Supply, create_supply};
use sui::event;

/**
Derived from https://github.com/kunalabs-io/sui-smart-contracts
Many thanks to @kkas for the original implementation!
*/

/* ================= errors ================= */

#[error]
const EZeroInput: vector<u8> = b"Input balances cannot be zero.";
#[error]
const ENoLiquidity: vector<u8> = b"Pool has no liquidity";
#[error]
const EInvalidFeeParam: vector<u8> = b"Fee parameter is not valid.";

/* ================= events ================= */

public struct PoolCreationEvent has copy, drop {
    pool_id: ID,
}

/* ================= constants ================= */

/// The number of basis points in 100%
const BPS_IN_100_PCT: u64 = 100 * 100;

/* ================= LP ================= */

/// Pool LP token witness.
public struct LP<phantom A, phantom B> has drop {}

/* ================= Pool ================= */

/// Pool represents an AMM Pool.
public struct Pool<phantom A, phantom B> has key {
    id: UID,
    balance_a: Balance<A>,
    balance_b: Balance<B>,
    lp_supply: Supply<LP<A, B>>,
    /// The liquidity provider fees expressed in basis points (1 bps is 0.01%)
    lp_fee_bps: u64,
    /// Admin fees are computed as a percentage of liquidity provider fees
    admin_fee_pct: u64,
    /// Admin fees are deposited into this balance. They can be collected by
    /// this pool's PoolAdminCap bearer.
    admin_fee_balance: Balance<LP<A, B>>,
}

/// Returns the value of collected admin fees stored in the pool.
public fun admin_fee_value<A, B>(pool: &Pool<A, B>): u64 {
    pool.admin_fee_balance.value()
}

/* ================= AdminCap ================= */

/// Capability allowing the bearer to execute admin operations on the pools
/// (e.g. withdraw admin fees). There's only one `AdminCap` created during module
/// initialization that's valid for all pools.
public struct AdminCap has key, store {
    id: UID,
}

/* ================= math ================= */

/// Calculates (a * b) / c. Errors if result doesn't fit into u64.
fun muldiv(a: u64, b: u64, c: u64): u64 {
    (((a as u128) * (b as u128)) / (c as u128)) as u64
}

/// Calculates ceil_div((a * b), c). Errors if result doesn't fit into u64.
fun ceil_muldiv(a: u64, b: u64, c: u64): u64 {
    u128::divide_and_round_up((a as u128) * (b as u128), c as u128) as u64
}

/// Calculates sqrt(a * b).
fun mulsqrt(a: u64, b: u64): u64 {
    sqrt((a as u128) * (b as u128))
}

fun sqrt(x: u128): u64 {
    u128::sqrt(x) as u64
}

/// Calculates (a * b) / c for u128. Errors if result doesn't fit into u128.
fun muldiv_u128(a: u128, b: u128, c: u128): u128 {
    (((a as u256) * (b as u256)) / (c as u256)) as u128
}

/* ================= main logic ================= */

/// Creates a new Pool with provided initial balances. Returns the initial LP coins.
public fun create<A, B>(
    init_a: Balance<A>,
    init_b: Balance<B>,
    lp_fee_bps: u64,
    admin_fee_pct: u64,
    ctx: &mut TxContext,
): Balance<LP<A, B>> {
    // sanity checks
    assert!(init_a.value() > 0 && init_b.value() > 0, EZeroInput);
    assert!(lp_fee_bps < BPS_IN_100_PCT, EInvalidFeeParam);
    assert!(admin_fee_pct <= 100, EInvalidFeeParam);

    // create pool
    let mut pool = Pool<A, B> {
        id: object::new(ctx),
        balance_a: init_a,
        balance_b: init_b,
        lp_supply: create_supply(LP<A, B> {}),
        lp_fee_bps,
        admin_fee_pct,
        admin_fee_balance: balance::zero<LP<A, B>>(),
    };

    // mint initial lp tokens
    let lp_amt = mulsqrt(pool.balance_a.value(), pool.balance_b.value());
    let lp_balance = pool.lp_supply.increase_supply(lp_amt);

    event::emit(PoolCreationEvent { pool_id: object::id(&pool) });
    transfer::share_object(pool);

    lp_balance
}

/// Deposit liquidity into pool. The deposit will use up the maximum amount of
/// the provided balances possible depending on the current pool ratio. Usually
/// this means that all of either `input_a` or `input_b` will be fully used, while
/// the other only partially. Otherwise, both input values will be fully used.
/// Returns the remaining input amounts (if any) and LP Coin of appropriate value.
public fun deposit<A, B>(
    pool: &mut Pool<A, B>,
    mut input_a: Balance<A>,
    mut input_b: Balance<B>,
): (Balance<A>, Balance<B>, Balance<LP<A, B>>) {
    // sanity checks
    if (input_a.value() == 0 || input_b.value() == 0) {
        return (input_a, input_b, balance::zero())
    };

    let (deposit_a, deposit_b, lp_to_issue) = generic_deposit(
        input_a.value(),
        input_b.value(),
        pool.balance_a.value(),
        pool.balance_b.value(),
        pool.lp_supply.supply_value(),
    );

    // deposit amounts into pool
    pool.balance_a.join(input_a.split(deposit_a));
    pool.balance_b.join(input_b.split(deposit_b));

    // mint lp coin
    let lp = pool.lp_supply.increase_supply(lp_to_issue);

    // return
    (input_a, input_b, lp)
}

fun generic_deposit(
    input_a_value: u64,
    input_b_value: u64,
    pool_a_value: u64,
    pool_b_value: u64,
    pool_lp_value: u64,
): (u64, u64, u64) {
    // compute the deposit amounts
    let dab: u128 = (input_a_value as u128) * (
        pool_b_value as u128,
    );
    let dba: u128 = (input_b_value as u128) * (
        pool_a_value as u128,
    );

    let deposit_a: u64;
    let deposit_b: u64;
    let lp_to_issue: u64;
    if (dab > dba) {
        deposit_b = input_b_value;
        deposit_a =
            u128::divide_and_round_up(
                dba,
                pool_b_value as u128,
            ) as u64;
        lp_to_issue =
            muldiv(
                deposit_b,
                pool_lp_value,
                pool_b_value,
            );
    } else if (dab < dba) {
        deposit_a = input_a_value;
        deposit_b =
            u128::divide_and_round_up(
                dab,
                pool_a_value as u128,
            ) as u64;
        lp_to_issue =
            muldiv(
                deposit_a,
                pool_lp_value,
                pool_a_value,
            );
    } else {
        deposit_a = input_a_value;
        deposit_b = input_b_value;
        if (pool_lp_value == 0) {
            // in this case both pool balances are 0 and lp supply is 0
            lp_to_issue = mulsqrt(deposit_a, deposit_b);
        } else {
            // the ratio of input a and b matches the ratio of pool balances
            lp_to_issue =
                muldiv(
                    deposit_a,
                    pool_lp_value,
                    pool_a_value,
                );
        }
    };

    (deposit_a, deposit_b, lp_to_issue)
}

/// Burns the provided LP Coin and withdraws corresponding pool balances.
public fun withdraw<A, B>(
    pool: &mut Pool<A, B>,
    lp_in: Balance<LP<A, B>>,
): (Balance<A>, Balance<B>) {
    // sanity checks
    if (lp_in.value() == 0) {
        lp_in.destroy_zero();
        return (balance::zero(), balance::zero())
    };

    // calculate output amounts
    let lp_in_value = lp_in.value();
    let pool_a_value = pool.balance_a.value();
    let pool_b_value = pool.balance_b.value();
    let pool_lp_value = pool.lp_supply.supply_value();

    let a_out = muldiv(lp_in_value, pool_a_value, pool_lp_value);
    let b_out = muldiv(lp_in_value, pool_b_value, pool_lp_value);

    // burn lp tokens
    pool.lp_supply.decrease_supply(lp_in);

    // return amounts
    (pool.balance_a.split(a_out), pool.balance_b.split(b_out))
}

/// Computes swap result and fees based on the input amount and current pool state.
fun generic_swap(
    a_value: u64,
    a_pool_value: u64,
    b_pool_value: u64,
    pool_lp_value: u64,
    lp_fee_bps: u64,
    admin_fee_pct: u64,
): (u64, u64) {
    // calc out value
    let lp_fee_value = ceil_muldiv(a_value, lp_fee_bps, BPS_IN_100_PCT);
    let in_after_lp_fee = a_value - lp_fee_value;
    let out_value = muldiv(
        in_after_lp_fee,
        b_pool_value,
        a_pool_value + in_after_lp_fee,
    );

    // calc admin fee
    let admin_fee_value = muldiv(lp_fee_value, admin_fee_pct, 100);
    // dL = L * sqrt((A + dA) / A) - L = sqrt(L^2(A + dA) / A) - L
    let result_pool_lp_value_sq = muldiv_u128(
        (pool_lp_value as u128) * (pool_lp_value as u128),
        ((a_pool_value + a_value) as u128),
        ((a_pool_value + a_value - admin_fee_value) as u128),
    );
    let admin_fee_in_lp = sqrt(result_pool_lp_value_sq) - pool_lp_value;

    (out_value, admin_fee_in_lp)
}

/// Swaps the provided amount of A for B.
public fun swap_a<A, B>(pool: &mut Pool<A, B>, input: Balance<A>): Balance<B> {
    if (input.value() == 0) {
        input.destroy_zero();
        return balance::zero()
    };
    assert!(pool.balance_a.value() > 0 && pool.balance_b.value() > 0, ENoLiquidity);

    // calculate swap result
    let i_value = input.value();
    let i_pool_value = pool.balance_a.value();
    let o_pool_value = pool.balance_b.value();
    let pool_lp_value = pool.lp_supply.supply_value();

    let (out_value, admin_fee_in_lp) = generic_swap(
        i_value,
        i_pool_value,
        o_pool_value,
        pool_lp_value,
        pool.lp_fee_bps,
        pool.admin_fee_pct,
    );

    // deposit admin fee
    pool.admin_fee_balance.join(pool.lp_supply.increase_supply(admin_fee_in_lp));

    // deposit input
    pool.balance_a.join(input);

    // return output
    pool.balance_b.split(out_value)
}

/// Swaps the provided amount of B for A.
public fun swap_b<A, B>(pool: &mut Pool<A, B>, input: Balance<B>): Balance<A> {
    if (input.value() == 0) {
        input.destroy_zero();
        return balance::zero()
    };
    assert!(pool.balance_a.value() > 0 && pool.balance_b.value() > 0, ENoLiquidity);

    // compute swap result
    let i_value = input.value();
    let i_pool_value = pool.balance_b.value();
    let o_pool_value = pool.balance_a.value();
    let pool_lp_value = pool.lp_supply.supply_value();

    let (out_value, admin_fee_in_lp) = generic_swap(
        i_value,
        i_pool_value,
        o_pool_value,
        pool_lp_value,
        pool.lp_fee_bps,
        pool.admin_fee_pct,
    );

    // deposit admin fee
    pool.admin_fee_balance.join(pool.lp_supply.increase_supply(admin_fee_in_lp));

    // deposit input
    pool.balance_b.join(input);

    // return output
    pool.balance_a.split(out_value)
}

/// Withdraw `amount` of collected admin fees by providing pool's PoolAdminCap.
/// When `amount` is set to 0, it will withdraw all available fees.
public fun admin_withdraw_fees<A, B>(
    pool: &mut Pool<A, B>,
    _: &AdminCap,
    mut amount: u64,
): Balance<LP<A, B>> {
    if (amount == 0) amount = pool.admin_fee_balance.value();
    pool.admin_fee_balance.split(amount)
}

/// Admin function. Set new fees for the pool.
public fun admin_set_fees<A, B>(
    pool: &mut Pool<A, B>,
    _: &AdminCap,
    lp_fee_bps: u64,
    admin_fee_pct: u64,
) {
    assert!(lp_fee_bps < BPS_IN_100_PCT, EInvalidFeeParam);
    assert!(admin_fee_pct <= 100, EInvalidFeeParam);

    pool.lp_fee_bps = lp_fee_bps;
    pool.admin_fee_pct = admin_fee_pct;
}

#[spec_only]
use prover::prover::{requires, ensures};

#[spec_only]
use std::integer;

#[spec]
fun sqrt_spec(x: u128): u64 {
    let result = sqrt(x);

    let result_int = result.to_int();
    let x_int = x.to_int();
    let result_int_plus_one = result_int.add(1u64.to_int());

    ensures(x_int.gte(result_int.mul(result_int)));
    ensures(x_int.lt(result_int_plus_one.mul(result_int_plus_one)));
    result
}

#[spec]
fun withdraw_spec<A, B>(pool: &mut Pool<A, B>, lp_in: Balance<LP<A, B>>): (Balance<A>, Balance<B>) {
    requires(pool.lp_supply.supply_value() > lp_in.value());

    let old_L = pool.lp_supply.supply_value();
    let old_A = pool.balance_a.value();
    let old_B = pool.balance_b.value();

    // l, a, b are either all 0 or all positive
    requires((old_L == 0 && old_A == 0 && old_B == 0) || (old_L > 0 && old_A > 0 && old_B > 0));

    // L * L <= A * B

    requires(old_L.to_int().mul(old_L.to_int()).lte(old_A.to_int().mul(old_B.to_int())));

    let (a_out, b_out) = withdraw(pool, lp_in);

    let new_L = pool.lp_supply.supply_value().to_int();
    let new_A = pool.balance_a.value().to_int();
    let new_B = pool.balance_b.value().to_int();
    // L * L <= A * B
    ensures(new_L.mul(new_L).lte(new_A.mul(new_B)));

    (a_out, b_out)
}

#[spec(verify)]
fun deposit_spec<A, B>(
    pool: &mut Pool<A, B>,
    input_a: Balance<A>,
    input_b: Balance<B>,
): (Balance<A>, Balance<B>, Balance<LP<A, B>>) {
    let old_L = pool.lp_supply.supply_value().to_int();
    let old_A = pool.balance_a.value().to_int();
    let old_B = pool.balance_b.value().to_int();

    requires(old_A.add(input_a.value().to_int()).lte(u64::max_value!().to_int()));
    requires(old_B.add(input_b.value().to_int()).lte(u64::max_value!().to_int()));

    requires(
        (old_L == integer::zero!() && old_A == integer::zero!() && old_B == integer::zero!()) ||
            (old_L != integer::zero!() && old_A != integer::zero!() && old_B != integer::zero!()),
    );

    // L * L <= A * B
    requires(old_L.mul(old_L).lte(old_A.mul(old_B)));

    let (deposit_a, deposit_b, lp_to_issue) = deposit(pool, input_a, input_b);

    let new_L = pool.lp_supply.supply_value().to_int();
    let new_A = pool.balance_a.value().to_int();
    let new_B = pool.balance_b.value().to_int();

    // L * L <= A * B
    ensures(new_L.mul(new_L).lte(new_A.mul(new_B)));

    // old_A / old_L <= new_A / new_L
    // old_A * new_L <= new_A * old_L
    ensures(old_A.mul(new_L).lte(new_A.mul(old_L)));

    // old_B / old_L <= new_B / new_L
    // old_B * new_L <= new_B * old_L
    ensures(old_B.mul(new_L).lte(new_B.mul(old_L)));

    // either all 0 or all positive
    ensures(
        (new_L == integer::zero!() && new_A == integer::zero!() && new_B == integer::zero!()) ||
            (new_L != integer::zero!() && new_A != integer::zero!() && new_B != integer::zero!()),
    );

    (deposit_a, deposit_b, lp_to_issue)
}
