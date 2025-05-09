#[allow(unused_function)]
module amm::pool;

use std::type_name::{Self, TypeName};
use std::u128;
use std::u64;
use sui::balance::{Self, Balance, Supply, create_supply};
use sui::event;
use sui::table::{Self, Table};

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

/* ================= spec only ================= */

#[spec_only]
use prover::prover::{requires, ensures, asserts, old};

/// Invariant for the pool state.
#[spec_only]
public use fun Pool_inv as Pool.inv;
#[spec_only]
fun Pool_inv<A, B>(self: &Pool<A, B>): bool {
    let l = self.lp_supply.supply_value();
    let a = self.balance_a.value();
    let b = self.balance_b.value();

    // Balances are 0 when LP supply is 0 or when LP supply > 0, both balances A and B are > 0
    ((l == 0 && a == 0 && b == 0) || (l > 0 && a > 0 && b > 0)) &&
    // The LP supply is always <= the geometric mean of the pool balances (this will make sure there is no overflow)
    l.to_int().mul(l.to_int()).lte(a.to_int().mul(b.to_int())) &&
    self.lp_fee_bps <= BPS_IN_100_PCT && self.admin_fee_pct <= 100
}

#[spec_only]
macro fun ensures_a_and_b_price_increases<$A, $B>($pool: &Pool<$A, $B>, $old_pool: &Pool<$A, $B>) {
    let pool = $pool;
    let old_pool = $old_pool;

    let old_L = old_pool.lp_supply.supply_value().to_int();
    let new_L = pool.lp_supply.supply_value().to_int();

    // (L + dL) * A <= (A + dA) * L
    let old_A = old_pool.balance_a.value().to_int();
    let new_A = pool.balance_a.value().to_int();
    ensures(new_L.mul(old_A).lte(new_A.mul(old_L)));

    // (L + dL) * B <= (B + dB) * L
    let old_B = old_pool.balance_b.value().to_int();
    let new_B = pool.balance_b.value().to_int();
    ensures(new_L.mul(old_B).lte(new_B.mul(old_L)));
}

#[spec_only]
macro fun ensures_product_price_increases<$A, $B>($pool: &Pool<$A, $B>, $old_pool: &Pool<$A, $B>) {
    let pool = $pool;
    let old_pool = $old_pool;

    let old_L = old_pool.lp_supply.supply_value().to_int();
    let new_L = pool.lp_supply.supply_value().to_int();
    let old_A = old_pool.balance_a.value().to_int();
    let new_A = pool.balance_a.value().to_int();
    let old_B = old_pool.balance_b.value().to_int();
    let new_B = pool.balance_b.value().to_int();

    // L'^2 * A * B <= L^2 * A' * B'
    ensures(new_L.mul(new_L).mul(old_A).mul(old_B).lte(old_L.mul(old_L).mul(new_A).mul(new_B)));
}

#[spec_only]
macro fun requires_balance_leq_supply<$T>($balance: &Balance<$T>, $supply: &Supply<$T>) {
    let balance = $balance;
    let supply = $supply;
    requires(balance.value() <= supply.supply_value());
}

#[spec_only]
macro fun requires_balance_sum_no_overflow<$T>($balance0: &Balance<$T>, $balance1: &Balance<$T>) {
    let balance0 = $balance0;
    let balance1 = $balance1;
    requires(balance0
        .value()
        .to_int()
        .add(balance1.value().to_int())
        .lt(u64::max_value!().to_int()));
}

/* ================= specs ================= */

#[spec(prove)]
fun create_spec<A, B>(
    init_a: Balance<A>,
    init_b: Balance<B>,
    lp_fee_bps: u64,
    admin_fee_pct: u64,
    ctx: &mut TxContext,
): Balance<LP<A, B>> {
    asserts(init_a.value() > 0 && init_b.value() > 0);
    asserts(lp_fee_bps < BPS_IN_100_PCT);
    asserts(admin_fee_pct <= 100);

    let result = create(init_a, init_b, lp_fee_bps, admin_fee_pct, ctx);

    ensures(result.value() > 0);

    result
}

#[spec(prove)]
fun deposit_spec<A, B>(
    pool: &mut Pool<A, B>,
    input_a: Balance<A>,
    input_b: Balance<B>,
): (Balance<A>, Balance<B>, Balance<LP<A, B>>) {
    requires_balance_sum_no_overflow!(&pool.balance_a, &input_a);
    requires_balance_sum_no_overflow!(&pool.balance_b, &input_b);

    // We also prove that `deposit` cannot generate any overflows or divisions by zero.
    // This is reflected in the spec by the fact that there are no asserts.

    let old_pool = old!(pool);

    let (result_input_a, result_input_b, result_lp) = deposit(pool, input_a, input_b);

    // prove that depositing liquidity always returns LPs of smaller value then what was deposited
    ensures_a_and_b_price_increases!(pool, old_pool);

    (result_input_a, result_input_b, result_lp)
}

#[spec(prove)]
fun generic_deposit_spec(
    input_a_value: u64,
    input_b_value: u64,
    pool_a_value: u64,
    pool_b_value: u64,
    pool_lp_value: u64,
): (u64, u64, u64) {
    let old_A = pool_a_value.to_int();
    let old_B = pool_b_value.to_int();
    let old_L = pool_lp_value.to_int();

    requires(0 < input_a_value);
    requires(0 < input_b_value);

    requires(
        old_L.is_zero!() && old_A.is_zero!() && old_B.is_zero!() || !old_L.is_zero!() && !old_A.is_zero!() && !old_B.is_zero!(),
    );

    // // L^2 <= A * B
    requires(old_L.mul(old_L).lte(old_A.mul(old_B)));

    // We also prove that `generic_deposit` cannot generate any overflows or divisions by zero.
    // This is reflected in the spec by the fact that there are no asserts.

    let (deposit_a, deposit_b, lp_to_issue) = generic_deposit(
        input_a_value,
        input_b_value,
        pool_a_value,
        pool_b_value,
        pool_lp_value,
    );

    let new_A = old_A.add(deposit_a.to_int());
    let new_B = old_B.add(deposit_b.to_int());
    let new_L = old_L.add(lp_to_issue.to_int());

    ensures(deposit_a <= input_a_value);
    ensures(deposit_b <= input_b_value);
    // ensures(new_L.lte(u64::max_value!().to_int()));

    ensures(
        new_L.is_zero!() && new_A.is_zero!() && new_B.is_zero!() || !new_L.is_zero!() && !new_A.is_zero!() && !new_B.is_zero!(),
    );

    // // (L + dL) * A <= (A + dA) * L
    ensures(new_L.mul(old_A).lte(new_A.mul(old_L)));
    // // (L + dL) * B <= (B + dB) * L
    ensures(new_L.mul(old_B).lte(new_B.mul(old_L)));
    // L^2 <= A * B
    ensures(new_L.mul(new_L).lte(new_A.mul(new_B)));

    (deposit_a, deposit_b, lp_to_issue)
}

#[spec(prove)]
fun withdraw_spec<A, B>(pool: &mut Pool<A, B>, lp_in: Balance<LP<A, B>>): (Balance<A>, Balance<B>) {
    requires_balance_leq_supply!(&lp_in, &pool.lp_supply);

    // We also prove that `withdraw` cannot generate any overflows or divisions by zero.
    // This is reflected in the spec by the fact that there are no asserts.

    let old_pool = old!(pool);

    let (result_a, result_b) = withdraw(pool, lp_in);

    // The invariant `Pool_inv` implies that when all LPs are withdrawn, both A and B go to zero.

    // Proving that withdrawing liquidity always returns A and B of smaller value then what was withdrawn.
    ensures_a_and_b_price_increases!(pool, old_pool);

    (result_a, result_b)
}

#[spec(prove)]
fun swap_a_spec<A, B>(pool: &mut Pool<A, B>, input: Balance<A>): Balance<B> {
    requires_balance_sum_no_overflow!(&pool.balance_a, &input);
    requires_balance_leq_supply!(&pool.admin_fee_balance, &pool.lp_supply);

    // Swapping on an empty pool is not possible.
    if (input.value() > 0) {
        asserts(pool.lp_supply.supply_value() > 0);
    };

    // We also prove that `swap_a` cannot generate any overflows or divisions by zero.
    // This is reflected in the spec by the fact that there are no asserts.

    let old_pool = old!(pool);

    let result = swap_a(pool, input);

    // L'^2 * A * B <= L^2 * A' * B'
    ensures_product_price_increases!(pool, old_pool);

    // swapping on a non-empty pool can never cause any pool balance to go to zero
    if (old_pool.lp_supply.supply_value() > 0) {
        ensures(pool.balance_a.value() > 0);
        ensures(pool.balance_b.value() > 0);
    };

    result
}

#[spec(prove)]
fun swap_b_spec<A, B>(pool: &mut Pool<A, B>, input: Balance<B>): Balance<A> {
    requires_balance_sum_no_overflow!(&pool.balance_b, &input);
    requires_balance_leq_supply!(&pool.admin_fee_balance, &pool.lp_supply);

    // swapping on an empty pool is not possible
    if (input.value() > 0) {
        asserts(pool.lp_supply.supply_value() > 0);
    };

    // We also prove that `swap_b` cannot generate any overflows or divisions by zero.
    // This is reflected in the spec by the fact that there are no asserts.

    let old_pool = old!(pool);

    let result = swap_b(pool, input);

    // L'^2 * A * B <= L^2 * A' * B'
    ensures_product_price_increases!(pool, old_pool);

    // swapping on a non-empty pool can never cause any pool balance to go to zero
    if (old_pool.lp_supply.supply_value() > 0) {
        ensures(pool.balance_a.value() > 0);
        ensures(pool.balance_b.value() > 0);
    };

    result
}

#[spec(prove)]
fun generic_swap_spec(
    i_value: u64,
    i_pool_value: u64,
    o_pool_value: u64,
    pool_lp_value: u64,
    lp_fee_bps: u64,
    admin_fee_pct: u64,
): (u64, u64) {
    requires(0 < i_pool_value);
    requires(0 < o_pool_value);
    requires(0 < pool_lp_value);

    let old_A = i_pool_value.to_int();
    let old_B = o_pool_value.to_int();
    let old_L = pool_lp_value.to_int();
    let new_A = old_A.add(i_value.to_int());

    requires(new_A.lt(u64::max_value!().to_int()));

    // L^2 <= A * B
    requires(old_L.mul(old_L).lte(old_A.mul(old_B)));

    requires(lp_fee_bps <= BPS_IN_100_PCT);
    requires(admin_fee_pct <= 100);

    // We also prove that `generic_swap` cannot generate any overflows or divisions by zero.
    // This is reflected in the spec by the fact that there are no asserts.

    let (out_value, admin_fee_in_lp) = generic_swap(
        i_value,
        i_pool_value,
        o_pool_value,
        pool_lp_value,
        lp_fee_bps,
        admin_fee_pct,
    );

    let new_B = old_B.sub(out_value.to_int());
    let new_L = old_L.add(admin_fee_in_lp.to_int());

    ensures(out_value <= o_pool_value);
    ensures(new_L.lte(u64::max_value!().to_int()));

    // L'^2 * A * B <= L^2 * A' * B'
    ensures(new_L.mul(new_L).mul(old_A).mul(old_B).lte(old_L.mul(old_L).mul(new_A).mul(new_B)));
    // L'^2 <= A' * B'
    ensures(new_L.mul(new_L).lte(new_A.mul(new_B)));

    (out_value, admin_fee_in_lp)
}

#[spec(prove)]
fun admin_set_fees_spec<A, B>(
    pool: &mut Pool<A, B>,
    cap: &AdminCap,
    lp_fee_bps: u64,
    admin_fee_pct: u64,
) {
    asserts(lp_fee_bps < BPS_IN_100_PCT);
    asserts(admin_fee_pct <= 100);
    admin_set_fees(pool, cap, lp_fee_bps, admin_fee_pct);
}
#[spec]
fun sqrt_spec(x: u128): u64 {
    let result = sqrt(x);
    ensures((result as u128) * (result as u128) <= x);
    ensures(((result as u256) + 1) * ((result as u256) + 1) > x as u256);
    result
}
