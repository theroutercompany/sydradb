import type { ScenarioRunResult } from "../shared/contracts.js";

function findStep(result: ScenarioRunResult, id: string) {
  return result.steps.find((step) => step.id === id);
}

function findSymbolMarkoutValue(
  groups: Array<{ key?: { symbol?: string }; horizons?: Array<{ value?: number }> }> | undefined,
  symbol: string,
) {
  return groups?.find((group) => group.key?.symbol === symbol)?.horizons?.[0]?.value
    ?? groups?.[0]?.horizons?.[0]?.value
    ?? null;
}

export function buildTradingSummaryEvidence(result: ScenarioRunResult): Record<string, unknown> | undefined {
  switch (result.scenarioId) {
    case "feed-and-schema": {
      const ingest = findStep(result, "ingest-baseline")?.output as { rows?: number; writes?: number };
      const tradeQuery = findStep(result, "query-aapl-trades")?.output as {
        rows?: Array<{ columns?: { price?: number } }>;
      };
      return {
        ingestedRows: ingest?.rows ?? 0,
        ingestedWrites: ingest?.writes ?? 0,
        sampleTradePrice: tradeQuery?.rows?.[0]?.columns?.price ?? null,
      };
    }
    case "bars-and-signals": {
      const rollups = findStep(result, "list-rollups")?.output as Array<{ runtime?: { emissions_total?: number } }>;
      const signals = findStep(result, "list-signals")?.output as Array<{ runtime?: { emissions_total?: number } }>;
      return {
        rollupEmissions: rollups?.[0]?.runtime?.emissions_total ?? 0,
        signalEmissions: signals?.[0]?.runtime?.emissions_total ?? 0,
      };
    }
    case "analysis-and-replay": {
      const before = findStep(result, "markout-before")?.output as {
        groups?: Array<{ key?: { symbol?: string }; horizons?: Array<{ value?: number }> }>;
      };
      const after = findStep(result, "markout-after")?.output as {
        groups?: Array<{ key?: { symbol?: string }; horizons?: Array<{ value?: number }> }>;
      };
      const diff = findStep(result, "diff-revisions")?.output as {
        wal_chunks_added?: number;
        series_entries_changed?: number;
        segments_added?: number;
      };
      return {
        beforeMarkoutValue: findSymbolMarkoutValue(before?.groups, "AAPL"),
        afterMarkoutValue: findSymbolMarkoutValue(after?.groups, "AAPL"),
        changedSeriesEntries: diff?.series_entries_changed ?? 0,
        segmentsAdded: diff?.segments_added ?? 0,
        walChunksAdded: diff?.wal_chunks_added ?? 0,
      };
    }
    default:
      return undefined;
  }
}
