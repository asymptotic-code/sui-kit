module showcase::vec_set;

use prover::prover::{ensures, old, requires};

use sui::vec_set;

fun foo(s: vec_set::VecSet<u64>): vec_set::VecSet<u64> {
    vec_set::from_keys(s.into_keys())
}

#[spec(prove)]
fun foo_spec(s: vec_set::VecSet<u64>): vec_set::VecSet<u64> {
  let old_s = old!(&s);
  let result = foo(s);
  ensures(&result == old_s);
  result
}


fun bar(s: &mut vec_set::VecSet<u64>) {
  s.insert(10);
}

#[spec(prove)]
fun bar_spec(s: &mut vec_set::VecSet<u64>) {
  requires(!s.contains(&10));
  bar(s);
  ensures(s.contains(&10));
}

fun baz(s: &mut vec_set::VecSet<u64>) {
  s.remove(&10);
}

#[spec(prove)]
fun baz_spec(s: &mut vec_set::VecSet<u64>) {
  requires(s.contains(&10));
  baz(s);
  ensures(!s.contains(&10));
}