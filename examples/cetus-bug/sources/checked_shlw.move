module integer_mate::math_u256;

#[spec_only]
use prover::prover::{ensures, requires};

public fun checked_shlw_buggy(n: u256): (u256, bool) {
    let mask = 0xffffffffffffffff << 192;
    if (n > mask) {
        (0, true)
    } else {
        ((n << 64), false)
    }
}

public fun checked_shlw_correct(n: u256): (u256, bool) {
    let mask = 1 << 192;
    if (n > mask) {
        (0, true)
    } else {
        ((n << 64), false)
    }
}

#[spec(prove)]
public fun checked_shlw_buggy_spec(n: u256): (u256, bool) {
    let (result, overflow) = checked_shlw_buggy(n);
    let n_int = n.to_int();
    let n_shifted = n_int.shl(64u64.to_int());
    ensures(overflow == (n_shifted != result.to_int()));
    (result, overflow)
}

#[spec(prove, focus)]
public fun checked_shlw_spec_correct(n: u256): (u256, bool) {
    let (result, overflow) = checked_shlw_correct(n);
    let n_int = n.to_int();
    let n_shifted = n_int.shl(64u64.to_int());
    ensures(overflow == (n_shifted != result.to_int()));
    (result, overflow)
}


