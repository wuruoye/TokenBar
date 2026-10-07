import type { GenerationMetrics, Tokens } from "./model";

interface MeasuredUsage {
  tokens: Tokens;
  generationMetrics?: GenerationMetrics | null;
  modelDurationMs?: number | null;
  averageGenerationTokensPerSecond?: number | null;
}

export function generationSample(value: MeasuredUsage): GenerationMetrics | undefined {
  const measured = value.generationMetrics;
  const generatedTokens = measured?.generatedTokens
    ?? ((value.tokens?.output ?? 0) + (value.tokens?.reasoning ?? 0));
  const durationMs = measured?.durationMs ?? value.modelDurationMs
    ?? (value.averageGenerationTokensPerSecond
      ? generatedTokens * 1000 / value.averageGenerationTokensPerSecond : 0);
  return Number.isFinite(generatedTokens) && generatedTokens > 0
    && Number.isFinite(durationMs) && durationMs > 0
    ? { generatedTokens, durationMs } : undefined;
}
