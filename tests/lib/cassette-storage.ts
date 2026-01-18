/**
 * Cassette Storage
 *
 * File I/O operations for loading and saving cassette files.
 * Uses Bun's native file APIs for performance.
 */

import { resolve, dirname, basename } from "node:path";
import type { Cassette } from "./cassette-types";
import {
  CASSETTE_VERSION,
  CassetteNotFoundError,
  CassetteParseError,
} from "./cassette-types";

// =============================================================================
// Constants
// =============================================================================

/** Default directory for cassette files relative to tests folder */
const DEFAULT_CASSETTES_DIR = "cassettes";

/** File extension for cassette files */
const CASSETTE_EXTENSION = ".json";

// =============================================================================
// Path Resolution
// =============================================================================

/**
 * Get the base cassettes directory path.
 * Defaults to tests/cassettes relative to the project root.
 */
export function getCassettesDir(): string {
  // Resolve relative to this file's location (tests/lib/)
  return resolve(dirname(import.meta.dir), DEFAULT_CASSETTES_DIR);
}

/**
 * Resolve a cassette name to its full file path.
 *
 * @param name - Cassette name, can be:
 *   - Simple name: "my-test" → tests/cassettes/my-test.json
 *   - Nested path: "conversations/chat" → tests/cassettes/conversations/chat.json
 *   - Full path: "/absolute/path/to/cassette.json" → used as-is
 *
 * @returns Absolute path to the cassette file
 */
export function resolveCassettePath(name: string): string {
  // If already an absolute path, use it
  if (name.startsWith("/")) {
    return name.endsWith(CASSETTE_EXTENSION)
      ? name
      : `${name}${CASSETTE_EXTENSION}`;
  }

  // Build path relative to cassettes directory
  const cassettesDir = getCassettesDir();
  const fileName = name.endsWith(CASSETTE_EXTENSION)
    ? name
    : `${name}${CASSETTE_EXTENSION}`;

  return resolve(cassettesDir, fileName);
}

/**
 * Extract cassette name from a file path.
 */
export function getCassetteName(filePath: string): string {
  const base = basename(filePath, CASSETTE_EXTENSION);
  return base;
}

// =============================================================================
// Directory Management
// =============================================================================

/**
 * Ensure the cassettes directory exists.
 * Creates parent directories recursively if needed.
 */
export async function ensureCassettesDir(dir?: string): Promise<void> {
  const targetDir = dir ?? getCassettesDir();

  try {
    await Bun.$`mkdir -p ${targetDir}`.quiet();
  } catch {
    // Directory might already exist, that's fine
  }
}

/**
 * Ensure the parent directory of a file path exists.
 */
async function ensureParentDir(filePath: string): Promise<void> {
  const parentDir = dirname(filePath);
  await ensureCassettesDir(parentDir);
}

// =============================================================================
// Load Operations
// =============================================================================

/**
 * Load a cassette from disk.
 *
 * @param path - Path to the cassette file (resolved via resolveCassettePath if relative)
 * @returns The loaded cassette
 * @throws CassetteNotFoundError if file doesn't exist
 * @throws CassetteParseError if file is invalid JSON
 */
export async function loadCassette(path: string): Promise<Cassette> {
  const fullPath = resolveCassettePath(path);
  const file = Bun.file(fullPath);

  // Check if file exists
  const exists = await file.exists();
  if (!exists) {
    throw new CassetteNotFoundError(fullPath);
  }

  // Read and parse file
  try {
    const content = await file.text();
    const cassette = JSON.parse(content) as Cassette;

    // Validate basic structure
    validateCassette(cassette, fullPath);

    // Reset _used flags for playback
    for (const interaction of cassette.interactions) {
      interaction._used = false;
    }

    return cassette;
  } catch (error) {
    if (error instanceof CassetteNotFoundError) {
      throw error;
    }
    if (error instanceof CassetteParseError) {
      throw error;
    }
    throw new CassetteParseError(fullPath, error as Error);
  }
}

/**
 * Check if a cassette file exists.
 */
export async function cassetteExists(path: string): Promise<boolean> {
  const fullPath = resolveCassettePath(path);
  const file = Bun.file(fullPath);
  return await file.exists();
}

// =============================================================================
// Save Operations
// =============================================================================

/**
 * Save a cassette to disk.
 *
 * @param path - Path to save the cassette (resolved via resolveCassettePath if relative)
 * @param cassette - The cassette to save
 */
export async function saveCassette(
  path: string,
  cassette: Cassette,
): Promise<void> {
  const fullPath = resolveCassettePath(path);

  // Ensure parent directory exists
  await ensureParentDir(fullPath);

  // Clean up internal fields before saving
  const cleanCassette = cleanForSave(cassette);

  // Format with 2-space indentation for readability
  const content = JSON.stringify(cleanCassette, null, 2);

  // Write file
  await Bun.write(fullPath, content);
}

/**
 * Remove internal tracking fields before saving.
 */
function cleanForSave(cassette: Cassette): Cassette {
  return {
    ...cassette,
    interactions: cassette.interactions.map((interaction) => {
      // Create a copy without the _used field
      const { _used, ...clean } = interaction;
      return clean;
    }),
  };
}

// =============================================================================
// Validation
// =============================================================================

/**
 * Validate cassette structure.
 */
function validateCassette(
  cassette: unknown,
  path: string,
): asserts cassette is Cassette {
  if (!cassette || typeof cassette !== "object") {
    throw new CassetteParseError(path, new Error("Cassette must be an object"));
  }

  const c = cassette as Record<string, unknown>;

  if (typeof c["version"] !== "number") {
    throw new CassetteParseError(
      path,
      new Error("Missing or invalid 'version' field"),
    );
  }

  if ((c["version"] as number) > CASSETTE_VERSION) {
    throw new CassetteParseError(
      path,
      new Error(
        `Cassette version ${c["version"]} is newer than supported version ${CASSETTE_VERSION}. ` +
          `Please update your cassette library.`,
      ),
    );
  }

  if (typeof c["name"] !== "string") {
    throw new CassetteParseError(
      path,
      new Error("Missing or invalid 'name' field"),
    );
  }

  if (!Array.isArray(c["interactions"])) {
    throw new CassetteParseError(
      path,
      new Error("Missing or invalid 'interactions' field"),
    );
  }

  // Validate each interaction
  const interactions = c["interactions"] as unknown[];
  for (let i = 0; i < interactions.length; i++) {
    validateInteraction(interactions[i], path, i);
  }
}

/**
 * Validate a single interaction.
 */
function validateInteraction(
  interaction: unknown,
  path: string,
  index: number,
): void {
  if (!interaction || typeof interaction !== "object") {
    throw new CassetteParseError(
      path,
      new Error(`Interaction at index ${index} must be an object`),
    );
  }

  const i = interaction as Record<string, unknown>;

  if (!i["request"] || typeof i["request"] !== "object") {
    throw new CassetteParseError(
      path,
      new Error(`Interaction at index ${index} missing 'request' field`),
    );
  }

  if (!i["response"] || typeof i["response"] !== "object") {
    throw new CassetteParseError(
      path,
      new Error(`Interaction at index ${index} missing 'response' field`),
    );
  }

  const req = i["request"] as Record<string, unknown>;
  if (typeof req["url"] !== "string") {
    throw new CassetteParseError(
      path,
      new Error(`Interaction at index ${index} has invalid 'request.url'`),
    );
  }

  if (typeof req["method"] !== "string") {
    throw new CassetteParseError(
      path,
      new Error(`Interaction at index ${index} has invalid 'request.method'`),
    );
  }

  const res = i["response"] as Record<string, unknown>;
  if (typeof res["statusCode"] !== "number") {
    throw new CassetteParseError(
      path,
      new Error(
        `Interaction at index ${index} has invalid 'response.statusCode'`,
      ),
    );
  }
}

// =============================================================================
// Factory Functions
// =============================================================================

/**
 * Create an empty cassette structure.
 *
 * @param name - Name for the cassette
 * @returns A new empty cassette ready for recording
 */
export function createEmptyCassette(name: string): Cassette {
  return {
    version: CASSETTE_VERSION,
    name,
    recordedAt: new Date().toISOString(),
    interactions: [],
  };
}

/**
 * List all cassette files in a directory.
 *
 * @param dir - Directory to search (defaults to cassettes dir)
 * @returns Array of cassette file paths
 */
export async function listCassettes(dir?: string): Promise<string[]> {
  const targetDir = dir ?? getCassettesDir();

  try {
    const glob = new Bun.Glob(`**/*${CASSETTE_EXTENSION}`);
    const files: string[] = [];

    for await (const file of glob.scan({ cwd: targetDir, absolute: true })) {
      files.push(file);
    }

    return files.sort();
  } catch {
    // Directory doesn't exist or other error
    return [];
  }
}
