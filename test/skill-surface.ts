// The pi-subagent MCP surface: the two live tools and every name the reduction removed.
// Shared by the stdio boundary test and the skill-contract test so the two cannot drift.
export const SUPPORTED_TOOLS = ["pi_delegate", "pi_status"] as const;

export const REMOVED_TOOLS = [
  "pi_plan",
  "pi_session_list",
  "pi_session_snapshot",
  "pi_session_fork",
  "pi_kill",
  "pi_task_create",
  "pi_task_plan",
  "pi_task_stage_run",
  "pi_task_stage_collect",
  "pi_task_list",
] as const;
