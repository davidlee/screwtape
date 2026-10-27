Observed in SL-003, 4 of 4 charters (RV-011..RV-014): an Opus adversarial
review subagent, spawned by an Opus sub-orchestrator that is itself a
background agent of the main thread, failed SubagentHandback ("the agent that
spawned me is no longer running"), though the parent was alive. Reports then
arrived late and by message, sometimes routed to the main thread instead.

How to apply when briefing a nested reviewer:
- Have it raise findings on the RV ledger directly; the ledger is the channel
  that never fails.
- Give it the parent's agent name and tell it to SendMessage its report as a
  fallback.
- The parent records the reviewer's verify/conclude acts from the ledger and
  says so on the ledger.
- Expect the late report to restate the verdict; reconcile the synthesis
  wording (charters 2–4 each needed a follow-up docs commit to correct
  "solid" vs "acceptable").
