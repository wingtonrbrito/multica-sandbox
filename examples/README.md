# Examples

Real outputs from agent runs in this sandbox. Each file is the actual code an LLM agent produced when given a natural-language spec, kept here as artifacts.

## Files

- [`api-hello-route.ts`](api-hello-route.ts) — engineer agent (Sonnet 4.6) output for the [strict RFC 7231 scenario](../scenarios/02-strict-rfc-spec.md). Single-file Next.js route handler exporting GET, HEAD, OPTIONS, and 405-returning POST/PUT/DELETE/PATCH. Approved by qa-review on first try.

## Why keep these

Two reasons:

1. **Proof of capability.** "Sonnet 4.6 produces this on first try given that spec" is more believable when you can read the actual output.
2. **Reference for skill design.** When you write specialist instructions or skills, knowing what your model actually produces under different prompts is the only way to calibrate.

If you want to verify reproducibility, fire the same scenario and diff the output. Should be substantively equivalent.
