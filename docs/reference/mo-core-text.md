# mo:core Text module

Quick reference for `mo:core/Text`, keeping the canonical doc comments/examples so assistants match upstream behavior.

## Import

```motoko name=import
import Text "mo:core/Text";

```

## Overview

```motoko
/// Utility functions for `Text` values.
///
/// A `Text` value represents human-readable text as a sequence of characters of type `Char`.

```

## Construction

````motoko
/// The type corresponding to primitive `Text` values.
public type Text = Prim.Types.Text;

/// Converts the given `Char` to a `Text` value.
///
/// ```motoko include=import
/// let text = Text.fromChar('A');
/// assert text == "A";
/// ```
public let fromChar : (c : Char) -> Text

/// Converts the given `[Char]` to a `Text` value.
///
/// ```motoko include=import
/// let text = Text.fromArray(['A', 'v', 'o', 'c', 'a', 'd', 'o']);
/// assert text == "Avocado";
/// ```
public func fromArray(a : [Char]) : Text

/// Converts the given `[var Char]` to a `Text` value.
///
/// ```motoko include=import
/// let text = Text.fromVarArray([var 'E', 'g', 'g', 'p', 'l', 'a', 'n', 't']);
/// assert text == "Eggplant";
/// ```
public func fromVarArray(a : [var Char]) : Text

/// Creates a `Text` value from a `Char` iterator.
///
/// ```motoko include=import
/// let text = Text.fromIter(['a', 'b', 'c'].values());
/// assert text == "abc";
/// ```
public func fromIter(cs : Iter.Iter<Char>) : Text;

````

## Iterating and inspecting

````motoko
/// Iterates over each `Char` value in the given `Text`.
/// Equivalent to calling the `t.chars()` method where `t` is a `Text` value.
///
/// ```motoko include=import
/// let chars = Text.toIter("abc");
/// assert chars.next() == ?'a';
/// assert chars.next() == ?'b';
/// assert chars.next() == ?'c';
/// assert chars.next() == null;
/// ```
public func toIter(self : Text) : Iter.Iter<Char>

/// Returns whether the given `Text` is empty (has a size of zero).
///
/// ```motoko include=import
/// let text1 = "";
/// let text2 = "example";
/// assert Text.isEmpty(text1);
/// assert not Text.isEmpty(text2);
/// ```
public func isEmpty(self : Text) : Bool

/// Returns the number of characters in the given `Text`.
///
/// ```motoko include=import
/// let size = Text.size("abc");
/// assert size == 3;
/// ```
public func size(self : Text) : Nat;

````

## Arrays back from Text

````motoko
/// Creates a new `Array` containing characters of the given `Text`.
/// Equivalent to `Iter.toArray(t.chars())`.
///
/// ```motoko include=import
/// assert Text.toArray("Café") == ['C', 'a', 'f', 'é'];
/// ```
public func toArray(self : Text) : [Char]

/// Creates a new mutable `Array` containing characters of the given `Text`.
///
/// ```motoko include=import
/// import VarArray "mo:core/VarArray";
/// import Char "mo:core/Char";
///
/// assert VarArray.equal(Text.toVarArray("Café"), [var 'C', 'a', 'f', 'é'], Char.equal);
/// ```
public func toVarArray(self : Text) : [var Char];

````

## Concatenation and reversal

````motoko
/// Returns `t1 # t2`, where `#` is the `Text` concatenation operator.
///
/// ```motoko include=import
/// let a = "Hello";
/// let b = "There";
/// let together = a # b;
/// assert together == "HelloThere";
/// let withSpace = a # " " # b;
/// assert withSpace == "Hello There";
/// let togetherAgain = Text.concat(a, b);
/// assert togetherAgain == "HelloThere";
/// ```
public func concat(self : Text, other : Text) : Text

/// Returns a new `Text` with the characters of the input `Text` in reverse order.
///
/// ```motoko include=import
/// let text = Text.reverse("Hello");
/// assert text == "olleH";
/// ```
public func reverse(self : Text) : Text;

````

## Comparison helpers

````motoko
/// Returns true if two text values are equal.
/// ```motoko
/// import Text "mo:core/Text";
///
/// assert Text.equal("hello", "hello");
/// assert not Text.equal("hello", "world");
/// ```
public func equal(self : Text, other : Text) : Bool

/// Returns true if the first text value is lexicographically less than the second.
/// ```motoko
/// import Text "mo:core/Text";
///
/// assert Text.less("apple", "banana");
/// assert not Text.less("banana", "apple");
/// ```
public func less(self : Text, other : Text) : Bool

/// Compares `t1` and `t2` lexicographically.
///
/// ```motoko include=import
/// assert Text.compare("abc", "abc") == #equal;
/// assert Text.compare("abc", "def") == #less;
/// assert Text.compare("abc", "ABC") == #greater;
/// ```
public func compare(self : Text, other : Text) : Order.Order;

````

## Joining and mapping characters

````motoko
/// Join an iterator of `Text` values with a given delimiter.
///
/// ```motoko include=import
/// let joined = Text.join(["a", "b", "c"].values(), ", ");
/// assert joined == "a, b, c";
/// ```
public func join(self : Iter.Iter<Text>, sep : Text) : Text

/// Applies a function to each character in a `Text` value, returning the concatenated `Char` results.
///
/// ```motoko include=import
/// // Replace all occurrences of '?' with '!'
/// let result = Text.map("Motoko?", func(c) {
///   if (c == '?') '!'
///   else c
/// });
/// assert result == "Motoko!";
/// ```
public func map(self : Text, f : Char -> Char) : Text

/// Returns the result of applying `f` to each character in `ts`, concatenating the intermediate text values.
///
/// ```motoko include=import
/// // Replace all occurrences of '?' with "!!"
/// let result = Text.flatMap("Motoko?", func(c) {
///   if (c == '?') "!!"
///   else Text.fromChar(c)
/// });
/// assert result == "Motoko!!";
/// ```
public func flatMap(self : Text, f : Char -> Text) : Text;

````

## Pattern operations (split/tokens/contains)

````motoko
/// Splits the input `Text` with the specified `Pattern`.
///
/// ```motoko include=import
/// let words = Text.split("This is a sentence.", #char ' ');
/// assert Text.join(words, "|") == "This|is|a|sentence.";
/// ```
public func split(self : Text, p : Pattern) : Iter.Iter<Text>

/// Returns a sequence of tokens from the input `Text` delimited by the specified `Pattern`.
///
/// ```motoko include=import
/// let tokens = Text.tokens("this needs\n an   example", #predicate (func(c) { c == ' ' or c == '\n' }));
/// assert Text.join(tokens, "|") == "this|needs|an|example";
/// ```
public func tokens(self : Text, p : Pattern) : Iter.Iter<Text>

/// Returns `true` if the input `Text` contains a match for the specified `Pattern`.
///
/// ```motoko include=import
/// assert Text.contains("Motoko", #text "oto");
/// assert not Text.contains("Motoko", #text "xyz");
/// ```
public func contains(self : Text, p : Pattern) : Bool

/// Returns `true` if the input `Text` starts with a prefix matching the specified `Pattern`.
///
/// ```motoko include=import
/// assert Text.startsWith("Motoko", #text "Mo");
/// ```
public func startsWith(self : Text, p : Pattern) : Bool

/// Returns `true` if the input `Text` ends with a suffix matching the specified `Pattern`.
///
/// ```motoko include=import
/// assert Text.endsWith("Motoko", #char 'o');
/// ```
public func endsWith(self : Text, p : Pattern) : Bool

/// Returns the input text `t` with all matches of pattern `p` replaced by text `r`.
///
/// ```motoko include=import
/// let result = Text.replace("abcabc", #char 'a', "A");
/// assert result == "AbcAbc";
/// ```
public func replace(self : Text, p : Pattern, r : Text) : Text;

````

---

These snippets stay verbatim with upstream `src/Text.mo`, ensuring Copilot/Claude can source the same canonical examples.
