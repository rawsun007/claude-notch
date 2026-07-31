#!/bin/bash
# Claude Code TaskCreated / TaskCompleted hook: feed the per-session task
# progress meter in ClaudeNotch. Fire-and-forget: these events CAN block Claude
# on exit 2 (TaskCreated rolls back, TaskCompleted blocks completion), so this
# always exits 0 and never emits a blocking decision.
set -u
COMMON="$(cd "$(dirname "$0")" && pwd)/claudenotch-common.sh"
[ -r "$COMMON" ] || exit 0
. "$COMMON"

# Field names confirmed empirically (Claude Code 2.1.x): TaskCreated/TaskCompleted
# carry task_id + task_subject + task_description. A few extra candidate keys are
# kept as a hedge against future schema drift.
notch_forward task task '{
    event:           (.hook_event_name // ""),
    task_id:         ((.task_id // .taskId // .task.id // .id // "") | tostring),
    subject:         (.task_subject // .subject // .title // .task.subject // .task_description // .description // ""),
    cwd:             (.cwd // ""),
    session_id:      (.session_id // ""),
    transcript_path: (.transcript_path // "")
}'
