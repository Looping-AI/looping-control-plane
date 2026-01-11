/**
 * Unwraps a Result<T, E> assuming it's an Ok variant
 * @param result - The result to unwrap
 * @returns The ok value
 * @throws Error if result is an Err variant
 */
export function expectOk<T>(result: { ok: T } | { err: string }): T {
  if ("err" in result) {
    throw new Error(`Expected Ok but got Err: ${result.err}`);
  }
  return result.ok;
}

/**
 * Unwraps a Result<T, E> assuming it's an Err variant
 * @param result - The result to unwrap
 * @returns The error value
 * @throws Error if result is an Ok variant
 */
export function expectErr(result: { ok: unknown } | { err: string }): string {
  if ("ok" in result) {
    throw new Error(`Expected Err but got Ok: ${JSON.stringify(result.ok)}`);
  }
  return result.err;
}

/**
 * Unwraps an optional array [T] assuming it contains a value
 * Motoko optionals are represented as arrays with 0 or 1 elements
 * @param optional - The optional array to unwrap
 * @returns The unwrapped value
 * @throws Error if optional is empty
 */
export function expectSome<T>(optional: T[]): T {
  if (optional.length === 0) {
    throw new Error("Expected Some but got None (empty array)");
  }
  return optional[0];
}

/**
 * Asserts that an optional array [] is empty (None in Motoko)
 * @param optional - The optional array to check
 * @throws Error if optional contains a value
 */
export function expectNone<T>(optional: T[]): void {
  if (optional.length > 0) {
    throw new Error(
      `Expected None but got Some: ${JSON.stringify(optional[0])}`,
    );
  }
}
