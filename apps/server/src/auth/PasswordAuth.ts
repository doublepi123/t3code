// @effect-diagnostics-next-line nodeBuiltinImport:off -- Effect's Crypto has no timingSafeEqual.
import * as NodeCrypto from "node:crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Redacted from "effect/Redacted";
import * as Ref from "effect/Ref";

import type { ServerConfig } from "../config.ts";

const MAX_FAILED_ATTEMPTS = 10;
const FAILURE_WINDOW_MS = 5 * 60 * 1000;

export interface PasswordAuth {
  /** False while throttled, so a guessed password cannot bypass the failure limit. */
  readonly matches: (credential: string) => Effect.Effect<boolean>;
  readonly recordFailure: Effect.Effect<void>;
}

export const resolvePasswordAuth = Effect.fn("PasswordAuth.resolve")(function* (
  config: Pick<ServerConfig["Service"], "authPassword">,
) {
  const password = config.authPassword;
  if (password === undefined) {
    return undefined;
  }
  const value = Redacted.value(password);
  if (value.length === 0) {
    return undefined;
  }
  const hash = NodeCrypto.createHash("sha256").update(value).digest();
  const failures = yield* Ref.make<ReadonlyArray<number>>([]);

  const recentFailureCount = Effect.gen(function* () {
    const now = DateTime.toEpochMillis(yield* DateTime.now);
    const recorded = yield* Ref.get(failures);
    return recorded.filter((at) => now - at < FAILURE_WINDOW_MS).length;
  });

  return {
    matches: (credential) =>
      recentFailureCount.pipe(
        Effect.flatMap((count) =>
          count >= MAX_FAILED_ATTEMPTS
            ? Effect.succeed(false)
            : Effect.sync(() =>
                NodeCrypto.timingSafeEqual(
                  hash,
                  NodeCrypto.createHash("sha256").update(credential).digest(),
                ),
              ),
        ),
      ),
    recordFailure: Effect.gen(function* () {
      const now = DateTime.toEpochMillis(yield* DateTime.now);
      yield* Ref.update(failures, (recorded) => [
        ...recorded.filter((at) => now - at < FAILURE_WINDOW_MS),
        now,
      ]);
    }),
  } satisfies PasswordAuth;
});
