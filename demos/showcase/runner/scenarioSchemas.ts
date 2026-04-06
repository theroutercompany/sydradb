import { z } from "zod";

const evidencePanelSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  kind: z.enum(["json", "command", "metrics", "query-stats", "rows", "note"]),
  sourcePath: z.string().optional(),
  description: z.string().optional(),
});

const assertionSchema = z.object({
  path: z.string(),
  operator: z.enum(["truthy", "equals", "includes", "gte", "minLength"]),
  value: z.unknown().optional(),
  message: z.string().optional(),
});

const stepBaseSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  summary: z.string().min(1),
  evidencePanels: z.array(evidencePanelSchema),
  assertions: z.array(assertionSchema).optional(),
});

const casCommandStepSchema = stepBaseSchema.extend({
  kind: z.literal("cas_command"),
  workspace: z.string().min(1),
  args: z.array(z.string()).min(1),
  json: z.boolean().optional(),
});

const shellCommandStepSchema = stepBaseSchema.extend({
  kind: z.literal("shell_command"),
  workspace: z.string().min(1),
  args: z.array(z.string()).min(1),
});

const sydraqlStepSchema = stepBaseSchema.extend({
  kind: z.literal("sydraql_query"),
  workspace: z.string().min(1),
  query: z.string().min(1),
});

const queryRangeStepSchema = stepBaseSchema.extend({
  kind: z.literal("query_range"),
  workspace: z.string().min(1),
  payload: z.record(z.unknown()),
});

const metricsStepSchema = stepBaseSchema.extend({
  kind: z.literal("metrics_snapshot"),
  workspace: z.string().min(1),
  counters: z.array(z.string()).min(1),
});

const serverControlStepSchema = stepBaseSchema.extend({
  kind: z.literal("server_control"),
  workspace: z.string().min(1),
  action: z.enum(["start", "stop", "restart"]),
});

export const scenarioManifestSchema = z.object({
  schemaVersion: z.literal(1),
  id: z.string().min(1),
  title: z.string().min(1),
  summary: z.string().min(1),
  maturity: z.enum(["experimental", "alpha", "candidate"]),
  subsystems: z.array(z.enum(["cas", "git-model", "sydraql", "compiler", "engine", "pgwire"])).min(1),
  requiredCapabilities: z.array(z.string()),
  minimumOutputs: z.array(z.string()),
  seedRoutine: z.string().min(1),
  cleanupRoutine: z.string().min(1),
  whySQLiteFallsShort: z.array(z.string()).min(1),
  steps: z.array(
    z.discriminatedUnion("kind", [
      casCommandStepSchema,
      shellCommandStepSchema,
      sydraqlStepSchema,
      queryRangeStepSchema,
      metricsStepSchema,
      serverControlStepSchema,
    ]),
  ),
});

