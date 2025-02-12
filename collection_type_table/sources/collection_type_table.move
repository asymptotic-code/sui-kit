/// A table that uses types as keys, allowing for type-based value storage and retrieval.
/// The table stores values of type V and uses Move types as keys.
module asymptotic::type_table;

use std::type_name::{Self, TypeName};
use sui::table::{Self, Table};

/// Represents a type-based table storing values of type V
/// The phantom parameter V ensures type safety while allowing the struct to be used generically
public struct TypeTable<phantom V: store> {
    /// The underlying table mapping type names to values
    table_values: Table<TypeName, V>,
}

/// Creates a new empty TypeTable
/// * `ctx` - The transaction context needed to create the table
/// Returns the newly created TypeTable
public fun create<V: store>(ctx: &mut TxContext): TypeTable<V> {
    TypeTable<V> {
        table_values: table::new<TypeName, V>(ctx),
    }
}

/// Adds a value to the table using type K as the key
/// * `table` - The table to add to
/// * `v` - The value to add
/// The type parameter K determines the key under which the value is stored
public fun add<K, V: store>(table: &mut TypeTable<V>, v: V) {
    table::add(&mut table.table_values, type_name::get<K>(), v);
}

/// Removes and returns the value associated with type K
/// * `table` - The table to remove from
/// Returns the value that was stored under type K
public fun remove<K, V: store>(table: &mut TypeTable<V>): V {
    table::remove(&mut table.table_values, type_name::get<K>())
}

/// Borrows a reference to the value associated with type K
/// * `table` - The table to borrow from
/// Returns an immutable reference to the value stored under type K
public fun borrow<K, V: store>(table: &TypeTable<V>): &V {
    table::borrow(&table.table_values, type_name::get<K>())
}

/// Borrows a mutable reference to the value associated with type K
/// * `table` - The table to borrow from
/// Returns a mutable reference to the value stored under type K
public fun borrow_mut<K, V: store>(table: &mut TypeTable<V>): &mut V {
    table::borrow_mut(&mut table.table_values, type_name::get<K>())
}

/// Checks if the table contains a value associated with type K
/// * `table` - The table to check
/// Returns true if a value exists for type K, false otherwise
public fun contains<K, V: store>(table: &TypeTable<V>): bool {
    table::contains(&table.table_values, type_name::get<K>())
}

/// Returns the number of entries in the table
/// * `table` - The table to get the length of
/// Returns the number of key-value pairs in the table
public fun length<V: store>(table: &TypeTable<V>): u64 {
    table::length(&table.table_values)
}
