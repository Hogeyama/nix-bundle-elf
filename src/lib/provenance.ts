// Records the inputs at the point they are copied, before ELF postprocessing.
import { createHash } from "node:crypto";
import { lstatSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";

export interface FileOrigin {
  source?: string;
  sourceSha256: string;
  generatedFrom?: string;
  changes: string[];
}
export type FileOrigins = Record<string, FileOrigin>;
export function digest(data: string | Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}
export function recordFile(
  origins: FileOrigins,
  destination: string,
  source: string,
  changes: string[],
): void {
  const actual = realpathSync(source);
  origins[destination] = { source: actual, sourceSha256: digest(readFileSync(actual)), changes };
}
export function recordInclude(origins: FileOrigins, destination: string, source: string): void {
  const actual = realpathSync(source);
  if (lstatSync(actual).isDirectory()) {
    for (const entry of readdirSync(actual).sort())
      recordInclude(origins, `${destination}/${entry}`, join(actual, entry));
  } else recordFile(origins, destination, actual, []);
}
