#!/bin/bash
# Claude Code TaskCreated / TaskCompleted hook: feed the per-session task
# progress meter in ClaudeNotch. Fire-and-forget — these events CAN block
# Claude on exit 2 (TaskCreated rolls back, TaskCompleted blocks completion),
# so we ALWAYS exit 0 and never emit a blocking decision.
set -u
LOG=/tmp/claudenotch-hook.log
input=$(cat)
echo "[$(date '+%H:%M:%S')] task hook fired" >> "$LOG"

nc -z 127.0.0.1 53127 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Field names confirmed empirically (Claude Code 2.1.x): TaskCreated/TaskCompleted
# carry task_id + task_subject + task_description. A few extra candidate keys are
# kept as a hedge against future schema drift.
printf '%s' "$input" | jq -c '{
    event:           (.hook_event_name // ""),
    task_id:         ((.task_id // .taskId // .task.id // .id // "") | tostring),
    subject:         (.task_subject // .subject // .title // .task.subject // .task_description // .description // ""),
    cwd:             (.cwd // ""),
    session_id:      (.session_id // ""),
    transcript_path: (.transcript_path // "")
}' | curl -s --max-time 2 -X POST \
       -H 'Content-Type: application/json' \
       --data-binary @- \
       http://127.0.0.1:53127/task >/dev/null || true
exit 0
