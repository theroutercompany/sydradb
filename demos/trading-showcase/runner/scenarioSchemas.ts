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

const waitStepSchema = stepBaseSchema.extend({
  kind: z.literal("wait"),
  durationMs: z.number().int().positive(),
});

const httpRequestStepSchema = stepBaseSchema.extend({
  kind: z.literal("http_request"),
  workspace: z.string().min(1),
  method: z.enum(["GET", "POST"]),
  path: z.string().min(1),
  body: z.union([z.string(), z.record(z.unknown())]).optional(),
  contentType: z.string().optional(),
  responseType: z.enum(["json", "text"]).optional(),
});

export const scenarioManifestSchema = z.object({
  schemaVersion: z.literal(1),
  id: z.string().min(1),
  title: z.string().min(1),
  summary: z.string().min(1),
  maturity: z.enum(["experimental", "alpha", "candidate"]),
  subsystems: z.array(z.string().min(1)).min(1),
  requiredCapabilities: z.array(z.string()),
  minimumOutputs: z.array(z.string()),
  seedRoutine: z.string().min(1),
  cleanupRoutine: z.string().min(1),
  whySQLiteFallsShort: z.array(z.string()).min(1),
  steps: z.array(
    z.discriminatedUnion("kind", [
      casCommandStepSchema,
      shellCommandStepSchema,
      waitStepSchema,
      httpRequestStepSchema,
    ]),
  ),
});
