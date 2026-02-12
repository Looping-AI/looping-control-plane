# mo:core Char module

Reference for `mo:core/Char`, mirroring the official doc comments and examples for Unicode code points.

## Import

```motoko name=import
import Char "mo:core/Char";

```

## Overview

```motoko
/// Module for working with Characters (Unicode code points).
///
/// Characters in Motoko represent Unicode code points
/// in the range 0 to 0x10FFFF, excluding the surrogate code points
/// (0xD800 through 0xDFFF).

```

## Conversion helpers

````motoko
/// Convert character `char` to a word containing its Unicode scalar value.
///
/// Example:
/// ```motoko include=import
/// let char = 'A';
/// let unicode = Char.toNat32(char);
/// assert unicode == 65;
/// ```
public let toNat32 : (self : Char) -> Nat32

/// Convert `w` to a character.
/// Traps if `w` is not a valid Unicode scalar value.
///
/// Example:
/// ```motoko include=import
/// let unicode : Nat32 = 65;
/// let char = Char.fromNat32(unicode);
/// assert char == 'A';
/// ```
public let fromNat32 : (nat32 : Nat32) -> Char

/// Convert character `char` to single character text.
///
/// Example:
/// ```motoko include=import
/// let char = '漢';
/// let text = Char.toText(char);
/// assert text == "漢";
/// ```
public let toText : (self : Char) -> Text;

````

## Character classification

````motoko
/// Returns `true` when `char` is a decimal digit between `0` and `9`, otherwise `false`.
///
/// Example:
/// ```motoko include=import
/// assert Char.isDigit('5');
/// assert not Char.isDigit('A');
/// ```
public func isDigit(self : Char) : Bool

/// Returns whether `char` is a whitespace character.
/// Whitespace characters include space, tab, newline, etc.
///
/// Example:
/// ```motoko include=import
/// assert Char.isWhitespace(' ');
/// assert Char.isWhitespace('\n');
/// assert not Char.isWhitespace('A');
/// ```
public let isWhitespace : (self : Char) -> Bool

/// Returns whether `char` is a lowercase character.
///
/// Example:
/// ```motoko include=import
/// assert Char.isLower('a');
/// assert not Char.isLower('A');
/// ```
public let isLower : (self : Char) -> Bool

/// Returns whether `char` is an uppercase character.
///
/// Example:
/// ```motoko include=import
/// assert Char.isUpper('A');
/// assert not Char.isUpper('a');
/// ```
public let isUpper : (self : Char) -> Bool

/// Returns whether `char` is an alphabetic character.
///
/// Example:
/// ```motoko include=import
/// assert Char.isAlphabetic('A');
/// assert Char.isAlphabetic('漢');
/// assert not Char.isAlphabetic('1');
/// ```
public func isAlphabetic(self : Char) : Bool;

````

## Comparisons

````motoko
/// Returns `a == b`.
///
/// Example:
/// ```motoko include=import
/// assert Char.equal('A', 'A');
/// assert not Char.equal('A', 'B');
/// ```
public func equal(self : Char, other : Char) : Bool

/// Returns `a != b`.
///
/// Example:
/// ```motoko include=import
/// assert Char.notEqual('A', 'B');
/// assert not Char.notEqual('A', 'A');
/// ```
public func notEqual(self : Char, other : Char) : Bool

/// Returns `a < b`.
///
/// Example:
/// ```motoko include=import
/// assert Char.less('A', 'B');
/// assert not Char.less('B', 'A');
/// ```
public func less(self : Char, other : Char) : Bool

/// Returns `a <= b`.
///
/// Example:
/// ```motoko include=import
/// assert Char.lessOrEqual('A', 'A');
/// assert Char.lessOrEqual('A', 'B');
/// assert not Char.lessOrEqual('B', 'A');
/// ```
public func lessOrEqual(self : Char, other : Char) : Bool

/// Returns `a > b`.
///
/// Example:
/// ```motoko include=import
/// assert Char.greater('B', 'A');
/// assert not Char.greater('A', 'B');
/// ```
public func greater(self : Char, other : Char) : Bool

/// Returns `a >= b`.
///
/// Example:
/// ```motoko include=import
/// assert Char.greaterOrEqual('B', 'A');
/// assert Char.greaterOrEqual('A', 'A');
/// assert not Char.greaterOrEqual('A', 'B');
/// ```
public func greaterOrEqual(self : Char, other : Char) : Bool

/// Returns the order of `a` and `b`.
///
/// Example:
/// ```motoko include=import
/// assert Char.compare('A', 'B') == #less;
/// assert Char.compare('B', 'A') == #greater;
/// assert Char.compare('A', 'A') == #equal;
/// ```
public func compare(self : Char, other : Char) : { #less; #equal; #greater };

````

---

This file mirrors `src/Char.mo` so AI tooling has immediate access to the canonical examples.
