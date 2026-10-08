# Initial 1,000-client saturation reset

The first V repetition passed, but the second connected 1,000 clients and then
lost them during saturation: only 211 of 3,945 posts reached everyone. All 30
paced messages had arrived. The series was stopped to diagnose the reset;
it is not the final comparison. The process was not killed by the OS.

The original full-series artifacts remain in
`.build/comparison/full-20261008T142041.933575Z`.

An isolated reproduction using the same production flags confirmed reactor
`1013 Mailbox full` closes. Its bounded server diagnostics and result are retained
here. The application follow-up partitions the same total connection/mailbox
budgets across four upstream reactor workers.

## Four-worker follow-up

The three `four-workers-*-result.json` files retain isolated fresh-seed tests of
the final four-worker application. All 1,000 clients subscribed and received all
30 paced messages in every repetition; **all three saturation cases failed**.
The accompanying server logs still show `1013 Mailbox full` closes. Partitioning
the budgets did not eliminate overload.

The [four-worker guard](four-workers-resource-guard.json) recorded 391.4 MiB
sampled peak, with zero memory-high, socket-throttling, OOM or OOM-kill events.
The [final full comparison](../../../rust-vs-v.md) independently passed two of
three 1,000-client cases; it does not establish reliable saturation capacity.
