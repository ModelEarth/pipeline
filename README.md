# Pipeline

## Getting Started

Setting up or managing Azure resources (SQL/PostgreSQL databases, schema deployment)? Start at
**[pipeline/azure](azure/)** for the automation script and its config.

.NET 10 database console (`DBMonitor/`) — see [CLAUDE.md](CLAUDE.md) for architecture and setup.
Used, among other things, to browse and query the Exiobase Industry Database instances described
in [exiobase/tradeflow](https://github.com/ModelEarth/exiobase/tree/main/tradeflow) and
[team/PLAN-merge.md](https://github.com/ModelEarth/team/blob/main/PLAN-merge.md).

**[View Schema](https://model.earth/exiobase/tradeflow/)** — live schema/row-count diagram for the
Industry Database, per year.

Also: [dblink permission setting](azure/dblink.md) - For moving data between [annual industry database](https://model.earth/exiobase/tradeflow/) instances.